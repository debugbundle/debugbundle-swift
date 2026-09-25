import Foundation
import XCTest
@testable import DebugBundle
import DebugBundleTestSupport

final class DebugBundleWireContractTests: XCTestCase {
    func testFrontendExceptionSerializesAsCanonicalMobileEnvelope() async throws {
        let transport = RecordingTransport()
        let client = makeClient(transport: transport)

        client.recordScreen("Checkout")
        client.captureException(
            NSError(domain: "Checkout", code: 42, userInfo: [NSLocalizedDescriptionKey: "checkout failed"]),
            context: ["screen": "Checkout"]
        )
        await client.flush()

        let batches = await transport.recordedBatches()
        let event = try XCTUnwrap(
            batches.flatMap { $0 }.first { $0.eventType == DebugBundleEventType.frontendException }
        )
        let encoded = try JSONEncoder().encode(event)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(root["schema_version"] as? String, "2026-03-01")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(root["event_id"] as? String)))
        XCTAssertNil(root["device"])
        XCTAssertEqual((root["service"] as? [String: Any])?["name"] as? String, "checkout-ios")
        XCTAssertEqual((root["context"] as? [String: Any])?["screen"] as? String, "Checkout")

        let payload = try XCTUnwrap(root["payload"] as? [String: Any])
        XCTAssertEqual(
            Set(payload.keys),
            Set(["name", "message", "stack", "breadcrumbs", "probe_data", "device"])
        )
        XCTAssertNil(payload["error"])
        XCTAssertNil(payload["context"])
        let device = try XCTUnwrap(payload["device"] as? [String: Any])
        XCTAssertEqual((device["os"] as? [String: Any])?["name"] as? String, "iOS")
        XCTAssertEqual(device["device_type"] as? String, "mobile")
    }

    func testAllSwiftEventPayloadsAreClosedAndCarryCanonicalDevice() async throws {
        let transport = RecordingTransport()
        let client = makeClient(transport: transport)
        await client.refreshRemoteConfig()

        client.captureLog("log", level: .error, context: ["logger": "checkout"])
        client.captureRequest(
            DebugBundleRequestInfo(method: "GET", url: "https://shop.example/checkout?cart=42"),
            response: DebugBundleResponseInfo(statusCode: 503, durationMillis: 25)
        )
        client.recordScreen("Checkout")
        client.probe("checkout.cart", data: ["cart", 42])
        for _ in 0 ..< 4 {
            client.captureException(NSError(domain: "Checkout", code: 42, userInfo: [NSLocalizedDescriptionKey: "same failure"]))
        }
        await client.flush()

        let batches = await transport.recordedBatches()
        let events = batches.flatMap { $0 }.reduce(into: [String: DebugBundleEventEnvelope]()) {
            $0[$1.eventType] = $1
        }
        assertPayload(events[DebugBundleEventType.logEvent], keys: ["level", "message", "attributes", "device"])
        assertPayload(
            events[DebugBundleEventType.requestEvent],
            keys: ["method", "path", "query", "headers", "response_status", "duration_ms", "response_headers", "device"]
        )
        assertPayload(
            events[DebugBundleEventType.frontendBreadcrumb],
            keys: ["breadcrumb_type", "route", "data", "device"]
        )
        assertPayload(
            events[DebugBundleEventType.probeEvent],
            keys: ["label", "data", "activation_id", "probe_label_pattern", "device"]
        )
        assertPayload(
            events[DebugBundleEventType.errorSuppressed],
            keys: ["fingerprint", "suppressed_count", "window_seconds", "first_seen", "last_seen", "device"]
        )

        let request = try XCTUnwrap(events[DebugBundleEventType.requestEvent])
        XCTAssertEqual(request.payload["path"], .string("/checkout"))
        XCTAssertNil(request.payload["url"])
        XCTAssertNotNil(request.payload["query"]?.objectValue)
        let probe = try XCTUnwrap(events[DebugBundleEventType.probeEvent])
        XCTAssertNotNil(probe.payload["data"]?.objectValue)
    }

    func testDirectIngestionWrapperUsesEventsKey() throws {
        let request = DebugBundleBatchRequest(events: [])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertNotNil(object["events"])
        XCTAssertNil(object["batch"])
    }

    func testLegacyCanonicalizationFallbackIsDeterministicAndPreservesUnknownPayloads() {
        let payload: [String: JSONValue] = [
            "message": .string("legacy"),
            "value": .number(42)
        ]
        let firstID = deterministicLegacySwiftEventId(
            sdkName: "@debugbundle/sdk-swift",
            eventType: "legacy_custom",
            service: "checkout-ios",
            occurredAt: "2026-05-29T10:00:00Z",
            payload: payload
        )
        let secondID = deterministicLegacySwiftEventId(
            sdkName: "@debugbundle/sdk-swift",
            eventType: "legacy_custom",
            service: "checkout-ios",
            occurredAt: "2026-05-29T10:00:00Z",
            payload: payload
        )
        let canonical = canonicalizeSwiftEvent(
            eventType: "legacy_custom",
            payload: payload,
            device: DebugBundleDeviceContext(),
            occurredAt: "2026-05-29T10:00:00Z"
        )

        XCTAssertNotNil(UUID(uuidString: firstID))
        XCTAssertEqual(firstID, secondID)
        XCTAssertEqual(canonical.payload, payload)
        XCTAssertNil(canonical.context)
    }

    private func assertPayload(_ event: DebugBundleEventEnvelope?, keys: Set<String>) {
        XCTAssertEqual(Set(event?.payload.keys.map { $0 } ?? []), keys)
        XCTAssertNotNil(event?.payload["device"]?.objectValue)
        XCTAssertNil(event?.payload["context"])
    }

    private func makeClient(transport: RecordingTransport) -> DebugBundleClient {
        makeIsolatedClient(
            config: DebugBundleConfig(
                projectToken: "token",
                service: "checkout-ios",
                batchSize: 20,
                flushInterval: 60,
                appVersion: "1.2.3",
                buildNumber: "42"
            ),
            transport: transport,
            remoteConfigClient: WireRemoteConfigClient(),
            connectivityMonitor: nil,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            random: { 0 },
            deviceContextProvider: {
                DebugBundleDeviceContext(
                    appVersion: "1.2.3",
                    buildNumber: "42",
                    releaseChannel: "production",
                    osName: "iOS",
                    osVersion: "18",
                    manufacturer: "Apple",
                    model: "iPhone",
                    deviceType: "mobile",
                    screenResolution: "1179x2556",
                    locale: "en-US",
                    timezone: "UTC",
                    networkConnectionType: "wifi",
                    batteryLevel: 80,
                    charging: false,
                    freeDiskBytes: 10_000,
                    freeMemoryBytes: 20_000,
                    jailbroken: false
                )
            }
        )
    }
}

private struct WireRemoteConfigClient: DebugBundleRemoteConfigClienting {
    func fetch(request _: DebugBundleRemoteConfigRequest) async -> DebugBundleRemoteConfigResult {
        .loaded(
            DebugBundleRemoteConfigResponse(
                probesEnabled: true,
                remoteProbesEnabled: true,
                activeProbes: [
                    DebugBundleRemoteProbeDirective(
                        activationId: "11111111-1111-4111-8111-111111111111",
                        labelPattern: "checkout.*",
                        service: "checkout-ios",
                        environment: "production",
                        expiresAt: "2036-05-28T10:15:30Z",
                        triggerExpiresAt: "2036-05-28T10:15:30Z"
                    )
                ],
                capturePolicy: DebugBundleRemoteCapturePolicy(
                    preset: "investigative",
                    captureLogs: "info",
                    captureRequestEvents: "all",
                    captureBreadcrumbs: "standalone",
                    captureProbeEvents: "standalone_when_activated"
                )
            ),
            eTag: nil
        )
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value
    }
}
