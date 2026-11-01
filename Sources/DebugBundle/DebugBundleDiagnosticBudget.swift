import Foundation

/// Accounts for retained metadata and pending observations together. Delivery never refunds allowances.
final class DebugBundleDiagnosticBudget {
    private struct Window {
        let start: Date
        var failureAt: Date?
        var failureId: String?
        var ambiguous = false
        var attempts = Set<String>()
        var observations = 0
        var pending = 0
        var resource = false
        func cost(_ key: String) -> Int { key.utf8.count + 256 + (failureId?.utf8.count ?? 0) + attempts.count * 40 }
    }
    private struct Receipt {
        let key: String
        let kind: String
        let attempt: String
        let bytes: Int
        var committed = false
        func cost(_ id: String) -> Int { bytes + key.utf8.count + id.utf8.count + 96 }
    }
    private let lock = NSRecursiveLock()
    private var windows: [String: Window] = [:]
    private var pending: [String: Receipt] = [:]
    private static let maximumBytes = 65_536
    private func synchronized<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    private func key(_ event: DebugBundleEventEnvelope, reference: [String: JSONValue]? = nil) -> String? {
        let item = reference ?? event.payload
        guard let scope = item["scope"], DebugBundleEvidenceWire.scope(scope),
              DebugBundleEvidenceWire.freshId(item["failure_ref"]?.stringValue) else { return nil }
        let value: JSONValue = .array([item["failure_ref"]!, scope, .string(event.service), .string(event.environment),
            event.correlation?.traceId.map(JSONValue.string) ?? .null, event.correlation?.sessionId.map(JSONValue.string) ?? .null])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), data.count <= Self.maximumBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func bytes(_ event: DebugBundleEventEnvelope) -> Int { (try? JSONEncoder().encode(event).count) ?? Int.max }
    private func size() -> Int { windows.reduce(0) { $0 + $1.value.cost($1.key) } + pending.reduce(0) { $0 + $1.value.cost($1.key) } }
    private func prune(_ now: Date) { windows = windows.filter { $0.value.pending > 0 || now.timeIntervalSince($0.value.start) < 300 } }

    @discardableResult func register(_ event: DebugBundleEventEnvelope) -> Bool { synchronized {
        guard debugBundleIsException(event.eventType), let reference = event.context?["evidence_reference"]?.objectValue,
              DebugBundleEvidenceWire.reference(.object(reference)), let now = debugBundleParseTimestamp(event.occurredAt),
              let key = key(event, reference: reference) else { return false }
        prune(now)
        let previous = windows[key]
        if let failure = previous?.failureId, failure != event.eventId { windows[key]?.ambiguous = true; return false }
        guard previous != nil || windows.count < 50 else { return false }
        var window = previous ?? Window(start: now)
        window.failureId = event.eventId
        if window.failureAt == nil { window.failureAt = now }
        guard size() - (previous?.cost(key) ?? 0) + window.cost(key) <= Self.maximumBytes else { return false }
        windows[key] = window
        return !window.ambiguous
    } }

    func reserve(_ event: DebugBundleEventEnvelope) -> Bool { synchronized {
        guard event.eventType == "diagnostic_context", pending[event.eventId] == nil else { return false }
        let count = bytes(event)
        guard count <= Self.maximumBytes, let now = debugBundleParseTimestamp(event.occurredAt), let key = key(event) else { return false }
        prune(now)
        let previous = windows[key]
        guard previous != nil || windows.count < 50 else { return false }
        var window = previous ?? Window(start: now)
        let failureAt = window.failureAt ?? window.start
        guard !window.ambiguous, now >= failureAt, now >= window.start, now.timeIntervalSince(failureAt) <= 300,
              window.observations < 20 else { return false }
        let kind = event.payload["kind"]?.stringValue ?? "", attempt = event.payload["attempt_id"]?.stringValue ?? ""
        switch kind {
        case "recovery":
            guard DebugBundleEvidenceWire.freshId(attempt), window.attempts.contains(attempt) || window.attempts.count < 5 else { return false }
            window.attempts.insert(attempt)
        case "resource_observation":
            guard !window.resource, window.failureAt != nil, window.failureId == event.payload["source_event_id"]?.stringValue,
                  now.timeIntervalSince(failureAt) <= 30 else { return false }
            window.resource = true
        default: return false
        }
        window.observations += 1; window.pending += 1
        let receipt = Receipt(key: key, kind: kind, attempt: attempt, bytes: count)
        guard size() - (previous?.cost(key) ?? 0) + window.cost(key) + receipt.cost(event.eventId) <= Self.maximumBytes else { return false }
        windows[key] = window; pending[event.eventId] = receipt
        return true
    } }

    func replace(_ originalId: String?, with event: DebugBundleEventEnvelope) -> Bool { synchronized {
        let original = originalId.flatMap { pending[$0] }
        guard let key = key(event) else { release(originalId); return false }
        let kind = event.payload["kind"]?.stringValue ?? "", attempt = event.payload["attempt_id"]?.stringValue ?? ""
        if let original, original.key == key, original.kind == kind, original.attempt == attempt, let originalId {
            let receipt = Receipt(key: key, kind: kind, attempt: attempt, bytes: bytes(event), committed: original.committed)
            guard receipt.bytes <= Self.maximumBytes, let window = windows[key], !window.ambiguous,
                  event.eventId == originalId || pending[event.eventId] == nil,
                  kind != "resource_observation" || window.failureId == event.payload["source_event_id"]?.stringValue,
                  size() - original.cost(originalId) + receipt.cost(event.eventId) <= Self.maximumBytes else { release(originalId); return false }
            pending.removeValue(forKey: originalId); pending[event.eventId] = receipt
            return true
        }
        release(originalId)
        return reserve(event)
    } }

    func eligible(_ event: DebugBundleEventEnvelope) -> Bool { synchronized {
        guard let receipt = pending[event.eventId], let key = key(event), let window = windows[key] else { return false }
        return !window.ambiguous && receipt.key == key && receipt.kind == event.payload["kind"]?.stringValue
            && receipt.attempt == (event.payload["attempt_id"]?.stringValue ?? "")
    } }
    func release(_ id: String?) { synchronized {
        if let id, let receipt = pending.removeValue(forKey: id), var window = windows[receipt.key] {
            window.pending = max(0, window.pending - 1); windows[receipt.key] = window
        }
    } }
    func restore(_ events: [DebugBundleEventEnvelope]) { synchronized {
        for event in events where debugBundleIsException(event.eventType) { register(event) }
        for event in events where event.eventType == "diagnostic_context" && pending[event.eventId] == nil { _ = reserve(event) }
        synchronize(events)
    } }
    func persisted(prepared: [DebugBundleEventEnvelope], retained: [DebugBundleEventEnvelope]) { synchronized {
        let ids = Set(retained.map(\.eventId))
        for event in prepared where event.eventType == "diagnostic_context" && !ids.contains(event.eventId) { release(event.eventId) }
        synchronize(retained)
    } }
    func synchronize(_ events: [DebugBundleEventEnvelope]) { synchronized {
        let ids = Set(events.map(\.eventId))
        let completed = pending.filter { $0.value.committed && !ids.contains($0.key) }.map(\.key)
        for id in completed { release(id) }
        for id in ids where pending[id] != nil { pending[id]?.committed = true }
    } }
    func clear() { synchronized { pending.removeAll(); windows.removeAll() } }
}
