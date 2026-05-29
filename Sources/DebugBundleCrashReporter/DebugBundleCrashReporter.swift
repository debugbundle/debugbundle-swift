import DebugBundle
import DebugBundleObjCExceptionShim
import Foundation

public struct DebugBundleCrashEvidence: Codable, Sendable, Equatable {
    public var version: Int
    public var mechanism: String
    public var errorType: String
    public var message: String
    public var occurredAt: String
    public var threadName: String
    public var stackTrace: [String]

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
}

public final class DebugBundleCrashEvidenceStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func persist(_ evidence: DebugBundleCrashEvidence) {
        let normalizedURL = fileURL.standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: normalizedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(evidence)
            let tempURL = normalizedURL.deletingLastPathComponent().appendingPathComponent("\(normalizedURL.lastPathComponent).tmp")
            try data.write(to: tempURL, options: .atomic)
            try replaceItem(at: normalizedURL, withItemAt: tempURL)
        } catch {
            return
        }
    }

    public func load() -> DebugBundleCrashEvidence? {
        guard let data = try? Data(contentsOf: fileURL.standardizedFileURL) else {
            return nil
        }
        return try? decoder.decode(DebugBundleCrashEvidence.self, from: data)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL.standardizedFileURL)
    }

    private func replaceItem(at destinationURL: URL, withItemAt sourceURL: URL) throws {
        do {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: sourceURL)
        } catch {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        }
    }
}

public enum DebugBundleCrashReporter {
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
            DebugBundleReplayedCrashError(evidence: evidence),
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
        let evidence = DebugBundleCrashEvidence(
            mechanism: mechanism,
            errorType: String(describing: type(of: error)),
            message: (error as NSError).localizedDescription,
            occurredAt: ISO8601DateFormatter().string(from: occurredAt),
            threadName: threadName ?? currentThreadName(),
            stackTrace: stackTrace
        )
        store.persist(evidence)
        return evidence
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
            report(
                error,
                context.merging(
                    [
                        "ns_exception_name": error.name,
                        "stack_trace": error.stackTrace,
                        "mechanism": "ns_exception"
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
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

private struct DebugBundleReplayedCrashError: LocalizedError {
    let evidence: DebugBundleCrashEvidence

    var errorDescription: String? {
        evidence.message
    }
}