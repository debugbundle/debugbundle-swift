import Foundation

public protocol DebugBundleQueueStoring {
    func load(now: Date, ttl: TimeInterval) -> [DebugBundleEventEnvelope]
    func persist(_ events: [DebugBundleEventEnvelope])
}

public final class DebugBundleFileQueueStore: DebugBundleQueueStoring {
    private let fileURL: URL
    private let fileProtection: DebugBundleFileProtection
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let formatter = ISO8601DateFormatter()
    private let maxReadBytes: Int
    private var privacyTransformer: ((DebugBundleEventEnvelope) -> DebugBundleEventEnvelope?)?

    public init(
        fileURL: URL,
        fileProtection: DebugBundleFileProtection = .completeUntilFirstUserAuthentication,
        maxReadBytes: Int = 5 * 1024 * 1024
    ) {
        self.fileURL = fileURL
        self.fileProtection = fileProtection
        self.maxReadBytes = max(1024, maxReadBytes)
    }

    func installPrivacyTransformer(_ transform: @escaping (DebugBundleEventEnvelope) -> DebugBundleEventEnvelope?) {
        lock.withLock { privacyTransformer = transform }
    }

    public func load(now: Date, ttl: TimeInterval) -> [DebugBundleEventEnvelope] {
        lock.withLock {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let size = attributes[.size] as? NSNumber, size.uint64Value <= UInt64(maxReadBytes) else {
                replaceUnreadableQueue()
                return []
            }
            guard let data = try? Data(contentsOf: fileURL) else {
                return []
            }
            guard let decoded = try? decoder.decode([DebugBundleEventEnvelope].self, from: data) else {
                replaceUnreadableQueue()
                return []
            }
            let retained = decoded.filter { envelope in
                guard let occurredAt = formatter.date(from: envelope.occurredAt) else {
                    return false
                }
                return now.timeIntervalSince(occurredAt) <= ttl
            }
            guard let privacyTransformer else { return retained }
            let safe = retained.compactMap { privacyTransformer($0) }
            // Atomic rewrite happens before any recovered event can enter the client buffer.
            guard let rewritten = try? encoder.encode(safe),
                  (try? rewritten.write(to: fileURL, options: .atomic)) != nil else { return [] }
            applyFileProtectionIfNeeded()
            return safe
        }
    }

    private func replaceUnreadableQueue() {
        if (try? Data("[]".utf8).write(to: fileURL, options: .atomic)) != nil {
            applyFileProtectionIfNeeded()
        }
    }

    public func persist(_ events: [DebugBundleEventEnvelope]) {
        lock.withLock {
            do {
                let directoryURL = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let data = try encoder.encode(events)
                try data.write(to: fileURL, options: .atomic)
                applyFileProtectionIfNeeded()
            } catch {
                return
            }
        }
    }

    private func applyFileProtectionIfNeeded() {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        let protectionType: FileProtectionType
        switch fileProtection {
        case .complete:
            protectionType = .complete
        case .completeUnlessOpen:
            protectionType = .completeUnlessOpen
        case .completeUntilFirstUserAuthentication:
            protectionType = .completeUntilFirstUserAuthentication
        case .none:
            protectionType = .none
        }

        try? FileManager.default.setAttributes(
            [.protectionKey: protectionType],
            ofItemAtPath: fileURL.path
        )
        #endif
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
