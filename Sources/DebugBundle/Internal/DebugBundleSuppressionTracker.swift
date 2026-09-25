import Foundation
import CryptoKit

struct DebugBundleSuppressionDecision {
    enum Action {
        case allow
        case suppress(suppressedCount: Int, windowSeconds: Int)
    }

    let action: Action
}

final class DebugBundleSuppressionTracker {
    private struct Entry {
        var timestamps: [Date] = []
        var suppressedCount: Int = 0
        var loopActive: Bool = false
        var lastSeen: Date?
        var lastCheckpointAt: Date?
    }

    private var entries: [String: Entry] = [:]
    private let duplicateWindow: TimeInterval = 30
    private let loopWindow: TimeInterval = 2
    private let loopThreshold = 10
    private let silenceResetWindow: TimeInterval = 60
    private let checkpointInterval: TimeInterval = 30

    func register(fingerprint: String, now: Date) -> DebugBundleSuppressionDecision {
        // Fixed-size keys and bounded timestamp history keep unique sustained bursts finite.
        let fingerprint = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        if entries[fingerprint] == nil, entries.count >= 2_048,
           let oldest = entries.min(by: { ($0.value.lastSeen ?? .distantPast) < ($1.value.lastSeen ?? .distantPast) })?.key {
            entries.removeValue(forKey: oldest)
        }
        var entry = entries[fingerprint] ?? Entry()

        if let lastSeen = entry.lastSeen, now.timeIntervalSince(lastSeen) >= silenceResetWindow {
            entry = Entry()
        }

        entry.lastSeen = now
        entry.timestamps = entry.timestamps.filter { now.timeIntervalSince($0) <= duplicateWindow }
        entry.timestamps.append(now)
        if entry.timestamps.count > loopThreshold + 1 { entry.timestamps.removeFirst(entry.timestamps.count - loopThreshold - 1) }
        let loopCount = entry.timestamps.filter { now.timeIntervalSince($0) <= loopWindow }.count

        if loopCount > loopThreshold {
            entry.loopActive = true
        }

        if entry.loopActive {
            let shouldEmitCheckpoint: Bool
            if let lastCheckpointAt = entry.lastCheckpointAt {
                shouldEmitCheckpoint = now.timeIntervalSince(lastCheckpointAt) >= checkpointInterval
            } else {
                shouldEmitCheckpoint = true
            }
            entry.suppressedCount = min(entry.suppressedCount, Int.max - 1) + 1
            if shouldEmitCheckpoint {
                entry.lastCheckpointAt = now
                entries[fingerprint] = entry
                return DebugBundleSuppressionDecision(action: .suppress(suppressedCount: entry.suppressedCount, windowSeconds: Int(duplicateWindow)))
            }
            entries[fingerprint] = entry
            return DebugBundleSuppressionDecision(action: .suppress(suppressedCount: 0, windowSeconds: Int(duplicateWindow)))
        }

        if entry.timestamps.count > 3 {
            entry.suppressedCount = min(entry.suppressedCount, Int.max - 1) + 1
            entries[fingerprint] = entry
            return DebugBundleSuppressionDecision(action: .suppress(suppressedCount: entry.suppressedCount, windowSeconds: Int(duplicateWindow)))
        }

        entries[fingerprint] = entry
        return DebugBundleSuppressionDecision(action: .allow)
    }
}