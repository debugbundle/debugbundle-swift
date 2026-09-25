import Foundation

/** One bounded ownership ledger shared by hook work, durable snapshots and sends. */
final class DebugBundleDeliveryQueue {
    struct Batch {
        let ids: [UUID]
        let events: [DebugBundleEventEnvelope]
    }
    struct Pressure {
        var count: Int
        var first: Date
        var last: Date
    }
    private final class Entry {
        let id = UUID()
        var event: DebugBundleEventEnvelope
        let deferredError: DebugBundleDeferredError?
        let needsDeviceContext: Bool
        var bytes: Int
        let capturedAt: Date
        var ready: Bool
        var leases = 0
        var removed = false
        init(_ event: DebugBundleEventEnvelope, bytes: Int, capturedAt: Date, ready: Bool, deferredError: DebugBundleDeferredError?, needsDeviceContext: Bool) {
            self.needsDeviceContext = needsDeviceContext
            self.deferredError = deferredError
            self.event = event; self.bytes = bytes; self.capturedAt = capturedAt; self.ready = ready
        }
    }
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "com.debugbundle.delivery", qos: .default)
    private let config: DebugBundleConfig
    private let store: DebugBundleQueueStoring
    private let clock: () -> Date
    private let protect: (DebugBundleEventEnvelope) -> DebugBundleEventEnvelope?
    private let prepare: (DebugBundleEventEnvelope, Date, DebugBundleDeferredError?, Bool) -> DebugBundleEventEnvelope?
    private let pressureEvent: (Pressure) -> DebugBundleEventEnvelope?
    private let onReady: () -> Void
    private var entries: [Entry] = []
    private var retainedBytes = 0
    private var loaded = false
    private var scheduled = false
    private var dirty = false
    private var version: UInt64 = 0
    private var pressureAttemptVersion: UInt64?
    private var pressure: Pressure?
    private var lastPressureReport: Date?
    private var idle = DebugBundleCompletion()

    init(config: DebugBundleConfig, store: DebugBundleQueueStoring, clock: @escaping () -> Date,
         protect: @escaping (DebugBundleEventEnvelope) -> DebugBundleEventEnvelope?,
         prepare: @escaping (DebugBundleEventEnvelope, Date, DebugBundleDeferredError?, Bool) -> DebugBundleEventEnvelope?,
         pressureEvent: @escaping (Pressure) -> DebugBundleEventEnvelope?, onReady: @escaping () -> Void) {
        self.config = config; self.store = store; self.clock = clock
        self.protect = protect; self.prepare = prepare; self.pressureEvent = pressureEvent; self.onReady = onReady
    }

    func start() { lock.withLock { scheduleLocked() } }

    func canAdmit(priority: Int) -> Bool {
        lock.withLock {
            pruneLocked()
            if entries.count < config.offlineQueueMaxEvents && retainedBytes < config.offlineQueueMaxBytes - 2 { return true }
            if entries.contains(where: { $0.leases == 0 && !$0.removed && Self.priority($0.event) < priority }) { return true }
            recordPressureLocked()
            return false
        }
    }

    @discardableResult
    func admit(_ event: DebugBundleEventEnvelope, ready: Bool = false, reportDrop: Bool = true, deferredError: DebugBundleDeferredError? = nil, needsDeviceContext: Bool = true) -> Bool {
        guard let bytes = encodedSize(event), bytes <= min(256 * 1024, config.offlineQueueMaxBytes - 2) else {
            if reportDrop { lock.withLock { recordPressureLocked() } }
            return false
        }
        return lock.withLock {
            pruneLocked()
            guard makeRoomLocked(bytes: bytes, priority: Self.priority(event), excluding: nil) else {
                if reportDrop { recordPressureLocked() }
                return false
            }
            let occurredAt = ready ? (debugBundleParseTimestamp(event.occurredAt) ?? clock()) : clock()
            entries.append(Entry(event, bytes: bytes, capturedAt: occurredAt, ready: ready, deferredError: deferredError, needsDeviceContext: needsDeviceContext))
            retainedBytes += bytes
            version &+= 1
            if ready { dirty = true }
            scheduleLocked()
            return true
        }
    }

    func waitUntilIdle(timeout: TimeInterval) async -> Bool {
        let signal = lock.withLock { () -> DebugBundleCompletion in
            scheduleLocked()
            return idle
        }
        return await signal.wait(timeout: timeout)
    }

    var readyCount: Int { lock.withLock { entries.filter { $0.ready && !$0.removed }.count } }
    var retainedCount: Int { lock.withLock { entries.count } }
    var byteCount: Int { lock.withLock { retainedBytes + 2 } }

    func takeBatch() -> Batch? {
        lock.withLock {
            pruneLocked()
            let selected = Array(entries.filter { $0.ready && !$0.removed }.prefix(config.batchSize))
            guard !selected.isEmpty else { return nil }
            selected.forEach { $0.leases += 1 }
            return Batch(ids: selected.map(\.id), events: selected.map(\.event))
        }
    }

    func finishBatch(_ batch: Batch, retryableIndices: Set<Int>) {
        lock.withLock {
            let sentIDs = Set(batch.ids)
            let retryIDs = Set(batch.ids.enumerated().compactMap { retryableIndices.contains($0.offset) ? $0.element : nil })
            for entry in entries where sentIDs.contains(entry.id) {
                if !retryIDs.contains(entry.id) { entry.removed = true; dirty = true }
                entry.leases -= 1
            }
            releaseRemovedLocked()
            version &+= 1
            scheduleLocked()
        }
    }

    private func scheduleLocked() {
        guard !scheduled else { return }
        scheduled = true
        idle = DebugBundleCompletion()
        worker.async { [self] in drain() }
    }

    private func drain() {
        if !loaded {
            // Recovery and mandatory historical scrubbing happen only on this worker.
            let recovered = store.load(now: clock(), ttl: config.offlineQueueTtl)
            for original in recovered.prefix(config.offlineQueueMaxEvents) {
                if let event = protect(original) { admit(event, ready: true) }
            }
            lock.withLock { loaded = true; dirty = true }
        }
        while true {
            let pending = lock.withLock { () -> Entry? in
                pruneLocked()
                guard let entry = entries.first(where: { !$0.ready && !$0.removed && $0.leases == 0 }) else { return nil }
                entry.leases += 1
                return entry
            }
            if let pending {
                let result = prepare(pending.event, pending.capturedAt, pending.deferredError, pending.needsDeviceContext)
                let bytes = result.flatMap(encodedSize)
                lock.withLock {
                    let replacementFits = result != nil && bytes != nil && bytes! <= min(256 * 1024, config.offlineQueueMaxBytes - 2)
                    if replacementFits, let result, let bytes,
                       makeRoomLocked(bytes: bytes, priority: Self.priority(result), excluding: pending) {
                        retainedBytes += bytes - pending.bytes
                        pending.event = result; pending.bytes = bytes; pending.ready = true; dirty = true
                    } else {
                        pending.removed = true
                        if result != nil { recordPressureLocked() }
                    }
                    pending.leases -= 1
                    releaseRemovedLocked()
                    version &+= 1
                }
                continue
            }
            if emitPressureIfPossible() { continue }
            let snapshot = lock.withLock { () -> [Entry]? in
                guard dirty else { return nil }
                dirty = false
                let ready = entries.filter { $0.ready && !$0.removed }
                ready.forEach { $0.leases += 1 }
                return ready
            }
            if let snapshot {
                // Leased snapshot bytes/count stay owned while even a custom store stalls.
                store.persist(snapshot.map(\.event))
                lock.withLock {
                    snapshot.forEach { $0.leases -= 1 }
                    releaseRemovedLocked()
                }
                continue
            }
            let signal = lock.withLock { () -> DebugBundleCompletion? in
                if dirty || entries.contains(where: { !$0.ready && !$0.removed }) { return nil }
                scheduled = false
                return idle
            }
            if let signal {
                signal.finish()
                onReady()
                return
            }
        }
    }

    private func emitPressureIfPossible() -> Bool {
        let snapshot = lock.withLock { () -> Pressure? in
            guard let pressure, pressureAttemptVersion != version,
                  entries.count < config.offlineQueueMaxEvents,
                  lastPressureReport == nil || clock().timeIntervalSince(lastPressureReport!) >= 30 else { return nil }
            pressureAttemptVersion = version
            self.pressure = nil
            return pressure
        }
        guard let snapshot else { return false }
        if let event = pressureEvent(snapshot), admit(event, reportDrop: false) {
            lock.withLock { lastPressureReport = clock() }
            return true
        }
        lock.withLock {
            if var current = pressure {
                current.count = current.count > Int.max - snapshot.count ? Int.max : current.count + snapshot.count
                current.first = min(current.first, snapshot.first)
                pressure = current
            } else { pressure = snapshot }
        }
        return false
    }

    private func makeRoomLocked(bytes: Int, priority: Int, excluding: Entry?) -> Bool {
        var count = entries.count - (excluding == nil ? 0 : 1)
        var ownedBytes = retainedBytes - (excluding?.bytes ?? 0)
        func fits() -> Bool { count < config.offlineQueueMaxEvents && ownedBytes <= config.offlineQueueMaxBytes - 2 - bytes }
        if fits() { return true }
        let candidates = entries.enumerated().filter {
            $0.element !== excluding && $0.element.leases == 0 && !$0.element.removed && Self.priority($0.element.event) < priority
        }.sorted {
            let left = Self.priority($0.element.event), right = Self.priority($1.element.event)
            return left == right ? $0.offset < $1.offset : left < right
        }
        var victims: [Entry] = []
        for candidate in candidates {
            victims.append(candidate.element)
            count -= 1; ownedBytes -= candidate.element.bytes
            if fits() { break }
        }
        // Admission is transactional: an event that cannot fit must not evict useful evidence.
        guard fits() else { return false }
        for victim in victims {
            victim.removed = true
            if victim.ready { dirty = true }
            recordPressureLocked()
        }
        releaseRemovedLocked()
        version &+= 1
        return true
    }

    private func pruneLocked() {
        let now = clock()
        for entry in entries where entry.leases == 0 && !entry.removed && now.timeIntervalSince(entry.capturedAt) > config.offlineQueueTtl {
            entry.removed = true
            if entry.ready { dirty = true }
            recordPressureLocked()
        }
        releaseRemovedLocked()
    }

    private func releaseRemovedLocked() {
        entries.removeAll { entry in
            if entry.removed && entry.leases == 0 { retainedBytes -= entry.bytes; return true }
            return false
        }
    }

    private func recordPressureLocked() {
        let now = clock()
        if pressure == nil { pressure = Pressure(count: 1, first: now, last: now) }
        else { pressure!.count = min(Int.max - 1, pressure!.count) + 1; pressure!.last = now }
    }

    private func encodedSize(_ event: DebugBundleEventEnvelope) -> Int? { (try? JSONEncoder().encode(event).count).map { $0 + 1 } }

    static func priority(_ event: DebugBundleEventEnvelope) -> Int {
        switch event.eventType {
        case DebugBundleEventType.frontendException: return 3
        case DebugBundleEventType.errorSuppressed: return 2
        case DebugBundleEventType.logEvent:
            return ["error", "critical"].contains(event.payload["level"]?.stringValue ?? "") ? 2 : 0
        case DebugBundleEventType.requestEvent:
            return (event.payload["response_status"]?.doubleValue ?? 0) >= 400 ? 2 : 1
        default: return 1
        }
    }
}

/** Deadline waiters are bounded independently of a stalled custom callback or transport. */
final class DebugBundleCompletion {
    private struct Waiter { let continuation: CheckedContinuation<Bool, Never>; let timer: DispatchWorkItem }
    private let lock = NSLock()
    private var finished = false
    private var waiters: [UUID: Waiter] = [:]

    func wait(timeout: TimeInterval) async -> Bool {
        guard timeout > 0 else { return false }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            let timer = DispatchWorkItem { [weak self] in self?.expire(id) }
            let immediate = lock.withLock { () -> Bool? in
                if finished { return true }
                if waiters.count >= 32 { return false }
                waiters[id] = Waiter(continuation: continuation, timer: timer)
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
            else { DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + min(timeout, 60), execute: timer) }
        }
    }

    func finish() {
        let pending = lock.withLock { () -> [Waiter] in
            finished = true
            let pending = Array(waiters.values); waiters.removeAll(); return pending
        }
        for waiter in pending { waiter.timer.cancel(); waiter.continuation.resume(returning: true) }
    }

    private func expire(_ id: UUID) {
        let waiter = lock.withLock { waiters.removeValue(forKey: id) }
        waiter?.continuation.resume(returning: false)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
