import Foundation
import XCTest
@testable import DebugBundle

final class DebugBundleAcknowledgementTests: XCTestCase {
    func testOverflowingAcknowledgementCountsRetainQueueWithoutCrashing() async {
        for (accepted, rejected) in [(Int.max, 1), (1, Int.max), (Int.min, 1)] {
            let queue = AcknowledgementQueueStore()
            let client = makeClient(
                transport: AcknowledgementTransport(result: .init(statusCode: 202,
                    acknowledgement: .init(accepted: accepted, rejected: rejected, errors: []))),
                queue: queue
            )
            client.captureMessage("retain", level: .error)
            await client.flush()
            XCTAssertEqual(client.status, .degraded)
            XCTAssertNil(client.lastEventAt)
            XCTAssertEqual(queue.events.count, 1)
        }
    }

    func testAllRejectedAcknowledgementNeverReportsDeliverySuccess() async {
        let queue = AcknowledgementQueueStore()
        let transport = AcknowledgementTransport(
            result: DebugBundleTransportResult(
                statusCode: 202,
                acknowledgement: DebugBundleIngestionAcknowledgement(
                    accepted: 0,
                    rejected: 1,
                    errors: [DebugBundleIngestionError(index: 0, reason: "invalid_event")]
                )
            )
        )
        let client = makeClient(transport: transport, queue: queue)

        client.captureMessage("rejected", level: .error)
        await client.flush()

        XCTAssertEqual(client.status, .disconnected)
        XCTAssertNil(client.lastEventAt)
        XCTAssertEqual(queue.events.count, 0)
    }

    func testPartialTerminalAcknowledgementRemovesAccountedBatchAndRecordsAcceptedDelivery() async {
        let queue = AcknowledgementQueueStore()
        let transport = AcknowledgementTransport(
            result: DebugBundleTransportResult(
                statusCode: 202,
                acknowledgement: DebugBundleIngestionAcknowledgement(
                    accepted: 1,
                    rejected: 1,
                    errors: [DebugBundleIngestionError(index: 1, reason: "capture_policy_rejected")]
                )
            )
        )
        let client = makeClient(transport: transport, queue: queue)

        client.captureMessage("accepted", level: .error)
        client.captureMessage("rejected", level: .error)
        await client.flush()

        XCTAssertEqual(client.status, .healthy)
        XCTAssertNotNil(client.lastEventAt)
        XCTAssertEqual(queue.events.count, 0)
    }

    func testPartialRetryableAcknowledgementRetainsOnlyRejectedIndex() async {
        let queue = AcknowledgementQueueStore()
        let transport = AcknowledgementTransport(
            result: DebugBundleTransportResult(
                statusCode: 202,
                acknowledgement: DebugBundleIngestionAcknowledgement(
                    accepted: 1,
                    rejected: 1,
                    errors: [DebugBundleIngestionError(index: 1, reason: "analytics_quota_exceeded")]
                )
            )
        )
        let client = makeClient(transport: transport, queue: queue)

        client.captureMessage("accepted", level: .error)
        client.captureMessage("retry", level: .error)
        await client.flush()

        XCTAssertEqual(client.status, .degraded)
        XCTAssertNotNil(client.lastEventAt)
        XCTAssertEqual(queue.events.count, 1)
        XCTAssertEqual(queue.events.first?.payload["message"], .string("retry"))
    }

    func testInconsistentAcknowledgementIsProtocolFailureAndRetainsQueue() async {
        let queue = AcknowledgementQueueStore()
        let transport = AcknowledgementTransport(
            result: DebugBundleTransportResult(
                statusCode: 202,
                acknowledgement: DebugBundleIngestionAcknowledgement(
                    accepted: 1,
                    rejected: 0,
                    errors: [DebugBundleIngestionError(index: 0, reason: "invalid_event")]
                )
            )
        )
        let client = makeClient(transport: transport, queue: queue)

        client.captureMessage("retain", level: .error)
        await client.flush()

        XCTAssertEqual(client.status, .degraded)
        XCTAssertNil(client.lastEventAt)
        XCTAssertEqual(queue.events.count, 1)
    }

    func testLegacyCustomTransportWithoutAcknowledgementPreservesSuccessFallback() async {
        let queue = AcknowledgementQueueStore()
        let client = makeClient(
            transport: AcknowledgementTransport(result: DebugBundleTransportResult(statusCode: 202)),
            queue: queue
        )

        client.captureMessage("legacy custom transport", level: .error)
        await client.flush()

        XCTAssertEqual(client.status, .healthy)
        XCTAssertNotNil(client.lastEventAt)
        XCTAssertEqual(queue.events.count, 0)
    }

    func testAcknowledgementAfterOverflowRetainsUnsentEventsAndOriginalRetryIndices() async {
        let outcomes: [(DebugBundleTransportResult, [String])] = [
            (.init(statusCode: 202), ["C"]),
            (.init(statusCode: 400), ["C"]),
            (.init(statusCode: 202, acknowledgement: .init(accepted: 1, rejected: 1,
                errors: [.init(index: 1, reason: "analytics_quota_exceeded")])), ["B", "C"])
        ]
        for (result, expected) in outcomes {
            let entered = expectation(description: "sender owns original batch")
            let queue = AcknowledgementQueueStore()
            let transport = HeldAcknowledgementTransport(result: result, entered: entered)
            let client = makeIsolatedClient(
                config: DebugBundleConfig(projectToken: "token", batchSize: 100, flushInterval: 3600,
                    offlineQueueMaxEvents: 3),
                transport: transport, queueStore: queue,
                remoteConfigClient: AcknowledgementRemoteConfigClient(),
                connectivityMonitor: AcknowledgementConnectivityMonitor(), random: { 0 }
            )
            client.captureLog("A", level: .error)
            client.captureLog("B", level: .error)
            let flush = Task { await client.flush() }
            await fulfillment(of: [entered], timeout: 2)
            client.captureLog("C", level: .error)
            client.captureLog("D", level: .error)
            await client.waitForPendingCapture()
            XCTAssertEqual(queue.events.map { $0.payload["message"] }, [.string("A"), .string("B"), .string("C")])
            await transport.release()
            await flush.value
            XCTAssertEqual(queue.events.compactMap { $0.payload["message"] }, expected.map(JSONValue.string))
        }
    }

    private func makeClient(
        transport: DebugBundleTransporting,
        queue: DebugBundleQueueStoring
    ) -> DebugBundleClient {
        makeIsolatedClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios", batchSize: 10, flushInterval: 60),
            transport: transport,
            queueStore: queue,
            remoteConfigClient: AcknowledgementRemoteConfigClient(),
            connectivityMonitor: AcknowledgementConnectivityMonitor(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            random: { 0 }
        )
    }
}

private actor AcknowledgementTransport: DebugBundleTransporting {
    let result: DebugBundleTransportResult

    init(result: DebugBundleTransportResult) {
        self.result = result
    }

    func send(
        events _: [DebugBundleEventEnvelope],
        config _: DebugBundleConfig
    ) async throws -> DebugBundleTransportResult {
        result
    }
}

private final class AcknowledgementQueueStore: DebugBundleQueueStoring {
    private(set) var events: [DebugBundleEventEnvelope] = []

    func load(now _: Date, ttl _: TimeInterval) -> [DebugBundleEventEnvelope] {
        events
    }

    func persist(_ events: [DebugBundleEventEnvelope]) {
        self.events = events
    }
}

private struct AcknowledgementRemoteConfigClient: DebugBundleRemoteConfigClienting {
    func fetch(request _: DebugBundleRemoteConfigRequest) async -> DebugBundleRemoteConfigResult {
        .notModified(eTag: nil)
    }
}

// A real path monitor can flush a partial batch before the fixed acknowledgement fixture.
private final class AcknowledgementConnectivityMonitor: DebugBundleConnectivityMonitoring {
    var currentStatus: DebugBundleConnectivityStatus { .connected }
    func setUpdateHandler(_ handler: (@Sendable (DebugBundleConnectivityStatus) -> Void)?) {}
}

private actor HeldAcknowledgementTransport: DebugBundleTransporting {
    let result: DebugBundleTransportResult
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(result: DebugBundleTransportResult, entered: XCTestExpectation) {
        self.result = result
        self.entered = entered
    }

    func send(events: [DebugBundleEventEnvelope], config: DebugBundleConfig) async throws -> DebugBundleTransportResult {
        await withCheckedContinuation {
            continuation = $0
            entered.fulfill()
        }
        return result
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
