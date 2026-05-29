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

    public init(
        fileURL: URL,
        fileProtection: DebugBundleFileProtection = .completeUntilFirstUserAuthentication
    ) {
        self.fileURL = fileURL
        self.fileProtection = fileProtection
    }

    public func load(now: Date, ttl: TimeInterval) -> [DebugBundleEventEnvelope] {
        lock.withLock {
            guard let data = try? Data(contentsOf: fileURL) else {
                return []
            }
            guard let decoded = try? decoder.decode([DebugBundleEventEnvelope].self, from: data) else {
                return []
            }
            return decoded.filter { envelope in
                guard let occurredAt = formatter.date(from: envelope.occurredAt) else {
                    return false
                }
                return now.timeIntervalSince(occurredAt) <= ttl
            }
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