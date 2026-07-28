import XCTest
@testable import DebugBundle
import DebugBundleTestSupport

final class DebugBundleFacadeTests: XCTestCase {
    override func tearDown() {
        DebugBundle.initialize(DebugBundleConfig(enabled: false))
        super.tearDown()
    }

    func testStaticFacadeDelegatesEveryPublicCaptureAndLifecycleOperation() async throws {
        let transport = RecordingTransport()
        _ = DebugBundle(
            DebugBundleConfig(
                projectToken: "token",
                service: "checkout-ios",
                batchSize: 100,
                flushInterval: 60
            )
        )
        DebugBundle.initialize(
            DebugBundleConfig(
                projectToken: "token",
                service: "checkout-ios",
                batchSize: 100,
                flushInterval: 60
            ),
            transport: transport
        )

        XCTAssertEqual(DebugBundle.status, .healthy)
        XCTAssertNil(DebugBundle.lastEventAt)
        DebugBundle.setContext("screen", value: "checkout")
        DebugBundle.recordBreadcrumb("custom", route: "/checkout", data: ["step": 1])
        DebugBundle.recordScreen("Checkout", previousScreen: "Cart")
        DebugBundle.recordAppForeground()
        DebugBundle.recordAppBackground()
        DebugBundle.recordAction("tap", targetType: "button", resourceName: "pay")
        DebugBundle.probe("checkout.total", data: 42)
        DebugBundle.probe("checkout.lazy", producer: { ["value": 7] })
        DebugBundle.captureLog("warning", level: .warning)
        DebugBundle.captureMessage("message", level: .error)
        DebugBundle.captureException(NSError(domain: "Facade", code: 1))
        DebugBundle.captureError(NSError(domain: "Facade", code: 2))
        DebugBundle.captureRequest(
            DebugBundleRequestInfo(method: "POST", url: "/checkout"),
            response: DebugBundleResponseInfo(statusCode: 503, durationMillis: 20)
        )

        XCTAssertFalse(DebugBundle.captureExternalEvent(["event_type": "invalid"]))
        XCTAssertFalse(DebugBundle.isExternalProbeActive("checkout.external"))
        XCTAssertFalse(
            DebugBundle.captureExternalProbe(
                sdkVersion: "1.1.0",
                service: "checkout-rn",
                environment: "production",
                label: "checkout.external",
                data: 1,
                occurredAt: "invalid"
            )
        )
        XCTAssertFalse(DebugBundle.activateProbeTriggerToken("invalid"))

        let value = try await DebugBundle.captureAsync { 42 }
        XCTAssertEqual(value, 42)
        let task = DebugBundle.captureTask { 43 }
        let taskValue = await task.value
        XCTAssertEqual(taskValue, 43)
        await DebugBundle.refreshRemoteConfig()
        await DebugBundle.flush()

        XCTAssertNotNil(DebugBundle.lastEventAt)
        let events = await transport.recordedBatches().flatMap { $0 }
        XCTAssertTrue(events.contains { $0.eventType == DebugBundleEventType.frontendException })
        XCTAssertTrue(events.contains { $0.eventType == DebugBundleEventType.logEvent })
        XCTAssertTrue(events.contains { $0.eventType == DebugBundleEventType.requestEvent })
    }
}
