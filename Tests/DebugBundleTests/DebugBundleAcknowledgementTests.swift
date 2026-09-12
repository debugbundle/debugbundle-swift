import Foundation
import XCTest
@testable import DebugBundle

final class DebugBundleAcknowledgementTests: XCTestCase {
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

    private func makeClient(
        transport: DebugBundleTransporting,
        queue: DebugBundleQueueStoring
    ) -> DebugBundleClient {
        DebugBundleClient(
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
