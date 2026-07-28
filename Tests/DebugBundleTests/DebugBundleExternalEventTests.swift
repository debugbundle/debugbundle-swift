import Foundation
import XCTest
@testable import DebugBundle
import DebugBundleTestSupport

final class DebugBundleExternalEventTests: XCTestCase {
    func testReactNativeExceptionPreservesIdentityErrorAndContextThroughNativeQueue() async throws {
        let transport = RecordingTransport()
        let client = makeClient(transport: transport)

        let captured = client.captureExternalEvent(
            externalEvent(
                eventType: DebugBundleEventType.frontendException,
                payload: [
                    "name": "TypeError",
                    "message": "checkout failed",
                    "stack": "TypeError: checkout failed\n at Checkout.tsx:42",
                    "breadcrumbs": [],
                    "probe_data": ["version": 1, "items": []]
                ],
                context: ["authorization": "Bearer secret", "screen": "Checkout"]
            )
        )
        await client.flush()

        XCTAssertTrue(captured)
        let batches = await transport.recordedBatches()
        let event = try XCTUnwrap(batches.first?.first)
        XCTAssertEqual(event.sdkName, "@debugbundle/sdk-react-native")
        XCTAssertEqual(event.serviceRuntime, "react-native")
        XCTAssertEqual(event.payload["name"], .string("TypeError"))
        XCTAssertEqual(event.payload["message"], .string("checkout failed"))
        XCTAssertEqual(event.context?["authorization"], .string("[REDACTED]"))
    }

    func testReactNativeEventAcceptsJavaScriptFractionalSecondTimestamp() async throws {
        let transport = RecordingTransport()
        let client = makeClient(transport: transport)
        var event = externalEvent(
            eventType: DebugBundleEventType.frontendException,
            payload: [
                "name": "Error",
                "message": "fractional timestamp",
                "stack": "Error: fractional timestamp"
            ]
        )
        event["occurred_at"] = "2026-05-28T10:15:30.123Z"

        XCTAssertTrue(client.captureExternalEvent(event))
        await client.flush()

        let batches = await transport.recordedBatches()
        let captured = try XCTUnwrap(batches.first?.first)
        XCTAssertEqual(captured.occurredAt, "2026-05-28T10:15:30.123Z")
    }

    func testExternalValidationIsClosedAndNativeRequestPolicyRemainsAuthoritative() async {
        let transport = RecordingTransport()
        let client = makeClient(
            transport: transport,
            capturePolicy: DebugBundleRemoteCapturePolicy(
                preset: "balanced",
                captureLogs: "warning",
                captureRequestEvents: "off",
                captureBreadcrumbs: "exception_only",
                captureProbeEvents: "buffer_only"
            )
        )
        await client.refreshRemoteConfig()

        var invalid = externalEvent(
            eventType: DebugBundleEventType.logEvent,
            payload: ["level": "error", "message": "invalid", "attributes": [:]]
        )
        invalid["unexpected"] = true
        XCTAssertFalse(client.captureExternalEvent(invalid))
        XCTAssertFalse(
            client.captureExternalEvent(
                externalEvent(
                    eventType: DebugBundleEventType.requestEvent,
                    payload: requestPayload(status: 200)
                )
            )
        )
        XCTAssertTrue(
            client.captureExternalEvent(
                externalEvent(
                    eventType: DebugBundleEventType.requestEvent,
                    payload: requestPayload(status: 503)
                )
            )
        )
        await client.flush()

        let batches = await transport.recordedBatches()
        XCTAssertEqual(batches.flatMap { $0 }.map(\.eventType), [DebugBundleEventType.requestEvent])
    }

    func testExternalProbeUsesNativeActivationAndPreservesReactNativeIdentity() async throws {
        let transport = RecordingTransport()
        let directive = DebugBundleRemoteProbeDirective(
            activationId: "11111111-1111-4111-8111-111111111111",
            labelPattern: "checkout.*",
            service: "checkout-rn",
            environment: "production",
            expiresAt: "2036-05-28T10:15:30Z",
            triggerExpiresAt: "2036-05-28T10:15:30Z"
        )
        let client = makeClient(
            transport: transport,
            capturePolicy: DebugBundleRemoteCapturePolicy(
                preset: "investigative",
                captureLogs: "info",
                captureRequestEvents: "all",
                captureBreadcrumbs: "standalone",
                captureProbeEvents: "standalone_when_activated"
            ),
            directives: [directive]
        )
        await client.refreshRemoteConfig()

        XCTAssertTrue(client.isExternalProbeActive("checkout.cart"))
        XCTAssertTrue(
            client.captureExternalProbe(
                sdkVersion: "1.1.0",
                service: "checkout-rn",
                environment: "production",
                label: "checkout.cart",
                data: ["cart", 42],
                occurredAt: "2026-05-28T10:15:30Z"
            )
        )
        await client.flush()

        let batches = await transport.recordedBatches()
        let event = try XCTUnwrap(batches.first?.first)
        XCTAssertEqual(event.sdkName, "@debugbundle/sdk-react-native")
        XCTAssertNotNil(event.payload["data"]?.objectValue)
        XCTAssertEqual(
            event.payload["data"]?.objectValue?["value"]?.arrayValue?.first,
            .string("cart")
        )
    }

    func testExternalDuplicateSuppressionAggregatePreservesReactNativeIdentity() async {
        let transport = RecordingTransport()
        let client = makeClient(transport: transport)
        for index in 1...4 {
            XCTAssertTrue(
                client.captureExternalEvent(
                    externalEvent(
                        eventType: DebugBundleEventType.frontendException,
                        payload: [
                            "name": "TypeError",
                            "message": "duplicate",
                            "stack": "TypeError: duplicate"
                        ],
                        eventId: String(format: "22222222-2222-4222-8222-%012d", index)
                    )
                )
            )
        }
        await client.flush()

        let events = await transport.recordedBatches().flatMap { $0 }
        XCTAssertEqual(events.map(\.eventType), [
            DebugBundleEventType.frontendException,
            DebugBundleEventType.frontendException,
            DebugBundleEventType.frontendException,
            DebugBundleEventType.errorSuppressed
        ])
        XCTAssertTrue(events.allSatisfy { $0.sdkName == "@debugbundle/sdk-react-native" })
    }

    private func makeClient(
        transport: RecordingTransport,
        capturePolicy: DebugBundleRemoteCapturePolicy = DebugBundleRemoteCapturePolicy(
            preset: "balanced",
            captureLogs: "warning",
            captureRequestEvents: "failures_only",
            captureBreadcrumbs: "exception_only",
            captureProbeEvents: "buffer_only"
        ),
        directives: [DebugBundleRemoteProbeDirective] = []
    ) -> DebugBundleClient {
        DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-rn", batchSize: 20, flushInterval: 60),
            transport: transport,
            remoteConfigClient: ExternalEventRemoteConfigClient(
                response: DebugBundleRemoteConfigResponse(
                    probesEnabled: true,
                    remoteProbesEnabled: true,
                    activeProbes: directives,
                    capturePolicy: capturePolicy
                )
            ),
            connectivityMonitor: nil,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            random: { 0 }
        )
    }

    private func externalEvent(
        eventType: String,
        payload: [String: Any?],
        context: [String: Any?]? = nil,
        eventId: String = "22222222-2222-4222-8222-222222222222"
    ) -> [String: Any?] {
        var event: [String: Any?] = [
            "schema_version": "2026-03-01",
            "event_id": eventId,
            "event_type": eventType,
            "sdk_name": "@debugbundle/sdk-react-native",
            "sdk_version": "1.1.0",
            "service": [
                "name": "checkout-rn",
                "environment": "production",
                "runtime": "react-native",
                "framework": "react-native"
            ],
            "occurred_at": "2026-05-28T10:15:30Z",
            "correlation": ["trace_id": "trace-rn"],
            "payload": payload,
            "device": [
                "app_version": "1.2.3",
                "build_number": "42",
                "release_channel": "production"
            ]
        ]
        if let context {
            event["context"] = context
        }
        return event
    }

    private func requestPayload(status: Int) -> [String: Any?] {
        [
            "method": "GET",
            "path": "/checkout",
            "query": [:],
            "headers": [:],
            "response_status": status,
            "duration_ms": 25,
            "response_headers": [:]
        ]
    }
}

private struct ExternalEventRemoteConfigClient: DebugBundleRemoteConfigClienting {
    let response: DebugBundleRemoteConfigResponse

    func fetch(request _: DebugBundleRemoteConfigRequest) async -> DebugBundleRemoteConfigResult {
        .loaded(response, eTag: nil)
    }
}
