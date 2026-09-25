import Foundation
import XCTest
@preconcurrency @testable import DebugBundle
import DebugBundleTestSupport

final class DebugBundleCaptureSafetyTests: XCTestCase {
    func testHeldPersistenceDoesNotHoldCaptureOrConcurrentCapture() async {
        let store = SafetyQueueStore()
        store.holdNonemptyWrites = true
        let client = makeClient(store: store)
        let firstReturned = expectation(description: "capture returned")
        DispatchQueue.global().async {
            client.captureLog("first", level: .error)
            firstReturned.fulfill()
        }
        await fulfillment(of: [store.entered], timeout: 2)
        let concurrentReturned = expectation(description: "concurrent capture returned")
        DispatchQueue.global().async {
            client.captureLog("second", level: .error)
            concurrentReturned.fulfill()
        }
        await fulfillment(of: [firstReturned, concurrentReturned], timeout: 0.25)
        store.release.signal()
        await client.flush()
    }

    func testHeldHookAndFullErrorQueueDoNotHoldCallersAndFlushHasDeadline() async {
        let entered = expectation(description: "hook entered")
        let release = DispatchSemaphore(value: 0)
        let hookCount = SafetyCounter()
        let transport = RecordingTransport()
        let client = makeClient(store: SafetyQueueStore(), maxEvents: 2, transport: transport, hook: { event in
            if hookCount.increment() == 1 {
                entered.fulfill()
                release.wait()
            }
            return event
        })
        let returned = expectation(description: "first capture returned")
        DispatchQueue.global().async {
            client.captureLog("first", level: .error)
            returned.fulfill()
        }
        await fulfillment(of: [entered, returned], timeout: 0.25)
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0 ..< 10_000 { client.captureLog("later-\(index)", level: .error) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertEqual(hookCount.value, 1)
        XCTAssertEqual(client.pendingCaptureCount, 2)
        let flushStart = ProcessInfo.processInfo.systemUptime
        await client.flush()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - flushStart, 0.5)
        release.signal()
        await drain(client, transport: transport, minimumEvents: 3)
        let delivered = await transport.recordedBatches().flatMap { $0 }
        XCTAssertEqual(delivered.filter { $0.eventType == DebugBundleEventType.logEvent }.count, 2)
        XCTAssertEqual(delivered.first { $0.payload["fingerprint"] == .string("swift-queue-pressure") }?.payload["suppressed_count"], .number(9_999))
    }

    func testBlockedStartupKeepsAdmissionBoundedAndPreservesPriorityAndPrivacy() async throws {
        let store = SafetyQueueStore()
        store.holdLoad = true
        let transport = RecordingTransport()
        let client = makeClient(store: store, maxEvents: 2, transport: transport)
        await fulfillment(of: [store.entered], timeout: 2)
        client.captureLog("reserved error", level: .error, context: ["password": "secret-before-retention"])
        client.captureLog("warning-two")
        client.captureException(NSError(domain: "Failure", code: 1, userInfo: [NSLocalizedDescriptionKey: "exception token=private-value"]))
        XCTAssertEqual(client.pendingCaptureCount, 2)
        XCTAssertLessThanOrEqual(client.pendingCaptureBytes, 5 * 1024 * 1024)
        let start = ProcessInfo.processInfo.systemUptime
        await client.flush()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        store.release.signal()
        await drain(client, transport: transport, minimumEvents: 2)
        let events = await transport.recordedBatches().flatMap { $0 }
        XCTAssertEqual(events.map(\.eventType), [DebugBundleEventType.logEvent, DebugBundleEventType.frontendException])
        let wire = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(wire.contains("private-value"))
        XCTAssertFalse(wire.contains("secret-before-retention"))
    }

    func testStalledTransportOwnsBatchAcrossConcurrentFlushDeadlines() async {
        let entered = expectation(description: "transport entered")
        let transport = HeldSafetyTransport(entered: entered)
        let hooks = SafetyCounter()
        let client = makeClient(store: SafetyQueueStore(), maxEvents: 2, transport: transport, hook: {
            _ = hooks.increment(); return $0
        })
        client.captureLog("first", level: .error)
        client.captureLog("second", level: .error)
        let initialFlush = Task { await client.flush() }
        await fulfillment(of: [entered], timeout: 2)
        let start = ProcessInfo.processInfo.systemUptime
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 100 { group.addTask { await client.flush() } }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.6)
        for index in 0 ..< 10_000 { client.captureLog("overflow-\(index)", level: .error) }
        XCTAssertEqual(hooks.value, 2)
        XCTAssertEqual(client.pendingCaptureCount, 2)
        let calls = await transport.calls
        XCTAssertEqual(calls, 1)
        await initialFlush.value
        await transport.release()
        await client.flush()
    }

    func testByteCapRejectsOversizedAndQueuedPayloadsBeforeHooks() async {
        let store = SafetyQueueStore()
        store.holdLoad = true
        let transport = RecordingTransport()
        let hooks = SafetyCounter()
        let client = makeIsolatedClient(config: DebugBundleConfig(projectToken: "token", batchSize: 100,
            requestTimeout: 0.1, offlineQueueMaxEvents: 100, offlineQueueMaxBytes: 4_096,
            beforeSend: { _ = hooks.increment(); return $0 }), transport: transport, queueStore: store,
            remoteConfigClient: SafetyConfigClient(), connectivityMonitor: SafetyConnectivity(), random: { 0 })
        await fulfillment(of: [store.entered], timeout: 2)
        client.captureLog(String(repeating: "a", count: 2_500), level: .error)
        client.captureLog(String(repeating: "b", count: 2_500), level: .error)
        client.captureLog(String(repeating: "c", count: 4_000), level: .error)
        XCTAssertEqual(client.pendingCaptureCount, 1)
        XCTAssertLessThanOrEqual(client.pendingCaptureBytes, 4_096)
        XCTAssertEqual(hooks.value, 0)
        store.release.signal()
        await drain(client, transport: transport, minimumEvents: 1)
        let events = await transport.recordedBatches().flatMap { $0 }
        XCTAssertEqual(events.first?.payload["message"], .string(String(repeating: "a", count: 2_500)))
        XCTAssertEqual(events.filter { $0.eventType == DebugBundleEventType.logEvent }.count, 1)
    }

    func testFinalHookPolicyAndExceptionSessionExemptionArePreserved() async {
        let transport = RecordingTransport()
        let client = makeIsolatedClient(config: DebugBundleConfig(projectToken: "token", batchSize: 100,
            maxEventsPerSession: 1, logLevel: .error, beforeSend: { original in
                var event = original
                if event.payload["message"] == .string("downgrade") { event.payload["level"] = .string("warning") }
                return event
            }), transport: transport, queueStore: SafetyQueueStore(), remoteConfigClient: SafetyConfigClient(),
            connectivityMonitor: SafetyConnectivity(), random: { 0 })
        client.captureLog("downgrade", level: .error)
        client.captureLog("eligible", level: .error)
        await client.flush()
        client.captureException(NSError(domain: "Still capture exceptions", code: 1))
        await client.flush()
        let events = await transport.recordedBatches().flatMap { $0 }
        XCTAssertEqual(events.map(\.eventType), [DebugBundleEventType.logEvent, DebugBundleEventType.frontendException])
        XCTAssertEqual(events.first?.payload["message"], .string("eligible"))
    }

    private func drain(_ client: DebugBundleClient, transport: RecordingTransport, minimumEvents: Int) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            await client.flush()
            if await transport.recordedBatches().flatMap({ $0 }).count >= minimumEvents { return }
            await Task.yield()
        }
    }

    private func makeClient(store: DebugBundleQueueStoring, maxEvents: Int = 10,
        transport: DebugBundleTransporting = RecordingTransport(), hook: DebugBundleBeforeSend? = nil) -> DebugBundleClient {
        makeIsolatedClient(config: DebugBundleConfig(projectToken: "token", batchSize: 100,
            flushInterval: 3600, requestTimeout: 0.1, offlineQueueMaxEvents: maxEvents, beforeSend: hook),
            transport: transport, queueStore: store,
            remoteConfigClient: SafetyConfigClient(), connectivityMonitor: SafetyConnectivity(), random: { 0 })
    }
}

private final class SafetyQueueStore: DebugBundleQueueStoring {
    let entered = XCTestExpectation(description: "persistence entered")
    let release = DispatchSemaphore(value: 0)
    var holdLoad = false
    var holdNonemptyWrites = false
    private var held = false
    func load(now: Date, ttl: TimeInterval) -> [DebugBundleEventEnvelope] {
        if holdLoad { entered.fulfill(); release.wait() }
        return []
    }
    func persist(_ events: [DebugBundleEventEnvelope]) {
        if holdNonemptyWrites && !events.isEmpty && !held {
            held = true
            entered.fulfill()
            release.wait()
        }
    }
}
private final class SafetyCounter {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
private struct SafetyConfigClient: DebugBundleRemoteConfigClienting {
    func fetch(request: DebugBundleRemoteConfigRequest) async -> DebugBundleRemoteConfigResult { .notModified(eTag: nil) }
}
private final class SafetyConnectivity: DebugBundleConnectivityMonitoring {
    var currentStatus: DebugBundleConnectivityStatus { .connected }
    func setUpdateHandler(_ handler: (@Sendable (DebugBundleConnectivityStatus) -> Void)?) {}
}

private actor HeldSafetyTransport: DebugBundleTransporting {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var calls = 0
    init(entered: XCTestExpectation) { self.entered = entered }
    func send(events: [DebugBundleEventEnvelope], config: DebugBundleConfig) async throws -> DebugBundleTransportResult {
        calls += 1
        if !released { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
        return DebugBundleTransportResult(statusCode: 202)
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
