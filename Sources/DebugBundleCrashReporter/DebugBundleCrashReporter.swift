@_spi(DebugBundleRuntime) import DebugBundle
import DebugBundleObjCExceptionShim
import Foundation
import Darwin

public enum DebugBundleCrashTraceOrigin: String, Codable, Sendable {
    case capture
    case nativeFatal = "native_fatal"
    case runtimeReported = "runtime_reported"
    case unknown
    case unavailable
}

public struct DebugBundleCrashEvidence: Codable, Sendable, Equatable {
    public var version: Int
    public var mechanism: String
    public var errorType: String
    public var message: String
    public var occurredAt: String
    public var threadName: String
    public var stackTrace: [String]
    public var traceOrigin: String = "unknown"
    public var eventId: String? = nil

    public init(
        version: Int = 1,
        mechanism: String = "manual",
        errorType: String,
        message: String,
        occurredAt: String,
        threadName: String? = nil,
        stackTrace: [String] = []
    ) {
        self.version = version
        self.mechanism = mechanism
        self.errorType = errorType
        self.message = message
        self.occurredAt = occurredAt
        self.threadName = threadName ?? DebugBundleCrashReporter.currentThreadName()
        self.stackTrace = Array(stackTrace.prefix(32))
    }
    private enum CodingKeys: String, CodingKey { case version, mechanism, errorType, message, occurredAt, threadName, stackTrace, traceOrigin, eventId }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        mechanism = try values.decode(String.self, forKey: .mechanism)
        errorType = try values.decode(String.self, forKey: .errorType)
        message = try values.decode(String.self, forKey: .message)
        occurredAt = try values.decode(String.self, forKey: .occurredAt)
        threadName = try values.decode(String.self, forKey: .threadName)
        stackTrace = Array(try values.decode([String].self, forKey: .stackTrace).prefix(32))
        traceOrigin = try values.decodeIfPresent(String.self, forKey: .traceOrigin) ?? "unknown"
        eventId = try values.decodeIfPresent(String.self, forKey: .eventId)
    }
}

public final class DebugBundleCrashEvidenceStore {
    private static let ioLock = NSLock()
    private let fileURL: URL
    private var redactFields = DebugBundleConfig.defaultRedactFields
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let maximumBytes = 262_144

    public init(fileURL: URL) { self.fileURL = fileURL }
    public init(fileURL: URL, redactFields: Set<String>) { self.fileURL = fileURL; self.redactFields = redactFields }

    func protect(_ original: DebugBundleCrashEvidence) -> DebugBundleCrashEvidence? {
        guard original.version == 1, DebugBundleRuntimeEvidence.validTimestamp(original.occurredAt), !original.errorType.isEmpty,
              DebugBundleCrashTraceOrigin(rawValue: original.traceOrigin) != nil,
              original.eventId.map(DebugBundleRuntimeEvidence.validEventId) != false else { return nil }
        var record = original
        func text(_ value: String, _ maximum: Int) -> String {
            DebugBundleRuntimeEvidence.boundedText(value, maximumBytes: maximum, redactFields: redactFields)
        }
        record.errorType = text(record.errorType, 256)
        record.message = text(record.message, 512)
        record.mechanism = text(record.mechanism, 64)
        record.threadName = text(record.threadName, 64)
        record.stackTrace = Array(record.stackTrace.prefix(32)).map { text($0, 512) }
        return record
    }
    private var normalizedURL: URL? {
        guard fileURL.isFileURL, fileURL.query == nil, fileURL.fragment == nil,
              fileURL.standardizedFileURL.path == fileURL.path else { return nil }
        let normalized = fileURL.standardizedFileURL
        if (try? normalized.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return nil }
        return normalized
    }
    public func persist(_ evidence: DebugBundleCrashEvidence) {
        guard Self.ioLock.try() else { return }
        defer { Self.ioLock.unlock() }
        _ = writeUnlocked(evidence)
    }
    private func writeUnlocked(_ evidence: DebugBundleCrashEvidence) -> Bool {
        guard let destination = normalizedURL, var protected = protect(evidence) else { return false }
        if protected.eventId == nil { protected.eventId = UUID().uuidString.lowercased() }
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(destination.lastPathComponent + "." + UUID().uuidString + ".tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return false }
            var target = stat()
            if lstat(destination.path, &target) == 0 && (target.st_mode & S_IFMT) != S_IFREG { return false }
            let data = try encoder.encode(protected)
            guard data.count <= Self.maximumBytes else { return false }
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
            guard descriptor >= 0 else { return false }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temporary.path, destination.path) == 0 else { return false }
            return true
        } catch { return false }
    }
    public func load() -> DebugBundleCrashEvidence? {
        guard Self.ioLock.try() else { return nil }
        defer { Self.ioLock.unlock() }
        return readUnlocked()
    }
    private func readUnlocked() -> DebugBundleCrashEvidence? {
        guard let file = normalizedURL else { return nil }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0, metadata.st_size <= Self.maximumBytes,
              let data = try? handle.read(upToCount: Self.maximumBytes + 1), data.count <= Self.maximumBytes,
              String(data: data, encoding: .utf8) != nil,
              let decoded = try? decoder.decode(DebugBundleCrashEvidence.self, from: data) else { return nil }
        return protect(decoded)
    }
    public func clear() {
        guard Self.ioLock.try() else { return }
        defer { Self.ioLock.unlock() }
        clearUnlocked()
    }
    private func clearUnlocked() {
        guard let file = normalizedURL else { return }
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else { return }
        try? FileManager.default.removeItem(at: file)
    }
    func prepareReplay() -> DebugBundleCrashEvidence? {
        guard Self.ioLock.try() else { return nil }
        defer { Self.ioLock.unlock() }
        guard var record = readUnlocked() else { return nil }
        if record.eventId == nil {
            record.eventId = UUID().uuidString.lowercased()
            guard writeUnlocked(record) else { return nil }
        }
        return record
    }
    func clearIfMatching(_ record: DebugBundleCrashEvidence) {
        guard Self.ioLock.try() else { return }
        defer { Self.ioLock.unlock() }
        if readUnlocked() == record { clearUnlocked() }
    }
}

public enum DebugBundleCrashReporter {
    @discardableResult public static func replayPendingCrash(store: DebugBundleCrashEvidenceStore) -> Bool {
        guard let record = store.prepareReplay(), let id = record.eventId else { return false }
        let report = DebugBundleRuntimeReport(eventId: id, name: record.errorType, message: record.message,
            occurredAt: record.occurredAt, stackTrace: record.stackTrace, traceOrigin: record.traceOrigin)
        return DebugBundle.captureRuntimeReport(report, context: replayContext(record), onRetained: { store.clearIfMatching(record) })
    }
    @discardableResult public static func replayPendingCrash(store: DebugBundleCrashEvidenceStore, client: DebugBundleClient) -> Bool {
        guard let record = store.prepareReplay(), let id = record.eventId else { return false }
        let report = DebugBundleRuntimeReport(eventId: id, name: record.errorType, message: record.message,
            occurredAt: record.occurredAt, stackTrace: record.stackTrace, traceOrigin: record.traceOrigin)
        return client.captureRuntimeReport(report, context: replayContext(record), onRetained: { store.clearIfMatching(record) })
    }
    private static func replayContext(_ record: DebugBundleCrashEvidence) -> [String: Any?] {
        ["fatal_crash": true, "crash_replayed": true, "mechanism": record.mechanism, "thread_name": record.threadName,
            "stack_trace": record.stackTrace, "occurred_at": record.occurredAt, "trace_origin": record.traceOrigin]
    }
    @discardableResult
    public static func replayPendingCrash(
        store: DebugBundleCrashEvidenceStore,
        report: (Error, [String: Any?]) -> Void = { error, context in
            DebugBundle.captureError(error, context: context)
        }
    ) -> Bool {
        guard let evidence = store.load() else {
            return false
        }

        report(
            NSError(domain: evidence.errorType, code: 0, userInfo: [NSLocalizedDescriptionKey: evidence.message]),
            [
                "fatal_crash": true,
                "crash_replayed": true,
                "mechanism": evidence.mechanism,
                "thread_name": evidence.threadName,
                "stack_trace": evidence.stackTrace,
                "occurred_at": evidence.occurredAt
            ]
        )
        store.clear()
        return true
    }

    @discardableResult
    public static func persistFatalCrash(
        _ error: Error,
        mechanism: String = "manual",
        store: DebugBundleCrashEvidenceStore,
        occurredAt: Date = Date(),
        threadName: String? = nil,
        stackTrace: [String] = Thread.callStackSymbols
    ) -> DebugBundleCrashEvidence {
        let evidence = fatalSnapshot(error, mechanism: mechanism, traceOrigin: .unknown, store: store,
            occurredAt: occurredAt, threadName: threadName, stackTrace: stackTrace)
        store.persist(evidence)
        return evidence
    }
    @discardableResult public static func persistFatalCrash(_ error: Error, mechanism: String = "manual",
        traceOrigin: DebugBundleCrashTraceOrigin, store: DebugBundleCrashEvidenceStore, occurredAt: Date = Date(),
        threadName: String? = nil, stackTrace: [String] = Thread.callStackSymbols) -> DebugBundleCrashEvidence {
        let evidence = fatalSnapshot(error, mechanism: mechanism, traceOrigin: traceOrigin, store: store,
            occurredAt: occurredAt, threadName: threadName, stackTrace: stackTrace)
        store.persist(evidence)
        return evidence
    }
    private static func fatalSnapshot(_ error: Error, mechanism: String, traceOrigin: DebugBundleCrashTraceOrigin,
        store: DebugBundleCrashEvidenceStore, occurredAt: Date, threadName: String?, stackTrace: [String]) -> DebugBundleCrashEvidence {
        let snapshot = DebugBundleRuntimeEvidence.fatalErrorSnapshot(error)
        let seconds = occurredAt.timeIntervalSince1970
        let timestamp = seconds.isFinite && (-62_135_596_800...253_402_300_799).contains(seconds)
            ? ISO8601DateFormatter().string(from: occurredAt) : ""
        var evidence = DebugBundleCrashEvidence(
            mechanism: DebugBundleRuntimeEvidence.boundedText(mechanism, maximumBytes: 64),
            errorType: snapshot.name,
            message: snapshot.message,
            occurredAt: timestamp,
            threadName: DebugBundleRuntimeEvidence.boundedText(threadName ?? currentThreadName(), maximumBytes: 64),
            stackTrace: stackTrace.prefix(32).map { DebugBundleRuntimeEvidence.boundedText($0, maximumBytes: 512) }
        )
        evidence.eventId = UUID().uuidString.lowercased()
        evidence.traceOrigin = traceOrigin.rawValue
        return store.protect(evidence) ?? evidence
    }

    public static func capture<T>(
        context: [String: Any?] = [:],
        report: (Error, [String: Any?]) -> Void = { error, reportContext in
            DebugBundle.captureError(error, context: reportContext)
        },
        operation: () throws -> T
    ) throws -> T {
        do {
            return try operation()
        } catch {
            report(error, context)
            throw error
        }
    }

    public static func captureAsync<T>(
        context: [String: Any?] = [:],
        report: @escaping (Error, [String: Any?]) -> Void = { error, reportContext in
            DebugBundle.captureError(error, context: reportContext)
        },
        operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            report(error, context)
            throw error
        }
    }

    public static func captureNSException<T>(
        context: [String: Any?] = [:],
        report: (Error, [String: Any?]) -> Void = { error, reportContext in
            DebugBundle.captureError(error, context: reportContext)
        },
        operation: @escaping () -> T
    ) throws -> T {
        try bridgeNSException(context: context, report: report, client: nil, native: false, operation: operation)
    }
    public static func captureNSException<T>(context: [String: Any?] = [:], operation: @escaping () -> T) throws -> T {
        try bridgeNSException(context: context, report: { _, _ in }, client: nil, native: true, operation: operation)
    }
    public static func captureNSException<T>(context: [String: Any?] = [:], client: DebugBundleClient, operation: @escaping () -> T) throws -> T {
        try bridgeNSException(context: context, report: { _, _ in }, client: client, native: true, operation: operation)
    }
    private static func bridgeNSException<T>(context: [String: Any?], report: (Error, [String: Any?]) -> Void,
        client: DebugBundleClient?, native: Bool, operation: @escaping () -> T) throws -> T {
        var result: T?
        var exceptionName: NSString?
        var exceptionReason: NSString?
        var stackTrace: NSArray?

        let didCatch = DebugBundleCatchNSException(
            {
                result = operation()
            },
            &exceptionName,
            &exceptionReason,
            &stackTrace
        )

        if didCatch {
            let error = DebugBundleObjCExceptionError(
                name: exceptionName as String? ?? "NSException",
                reason: exceptionReason as String? ?? "Objective-C exception raised",
                stackTrace: (stackTrace as? [String]) ?? []
            )
            let metadata = context.merging(["ns_exception_name": error.name, "stack_trace": error.stackTrace, "mechanism": "ns_exception"], uniquingKeysWith: { _, new in new })
            if !native {
                // Explicit legacy reporters retain their caller-owned callback and error contract.
                report(NSError(domain: error.name, code: 0, userInfo: [NSLocalizedDescriptionKey: error.reason]), metadata)
            } else {
                var native = DebugBundleRuntimeReport(eventId: UUID().uuidString.lowercased(), name: error.name, message: error.reason,
                    occurredAt: ISO8601DateFormatter().string(from: Date()), stackTrace: error.stackTrace, traceOrigin: error.stackTrace.isEmpty ? "unavailable" : "runtime_reported")
                native.isCurrent = true
                if let client { client.captureRuntimeReport(native, context: metadata) }
                else { DebugBundle.captureRuntimeReport(native, context: metadata) }
            }
            throw error
        }

        return result!
    }

    static func currentThreadName() -> String {
        if Thread.isMainThread {
            return "main"
        }

        if let name = Thread.current.name, !name.isEmpty {
            return name
        }

        return "background"
    }
}

public struct DebugBundleObjCExceptionError: LocalizedError, Sendable, Equatable {
    public var name: String
    public var reason: String
    public var stackTrace: [String]

    public init(name: String, reason: String, stackTrace: [String] = []) {
        self.name = name
        self.reason = reason
        self.stackTrace = stackTrace
    }

    public var errorDescription: String? {
        reason
    }
}
