import DebugBundleTestSupport
import Foundation
import XCTest
@testable import DebugBundle

final class DebugBundleFixturesTests: XCTestCase {
    func testCapturedBatchSupportsCanonicalAndLegacyWrappersAndLookup() throws {
        let event = DebugBundleEventEnvelope(
            sdkName: "@debugbundle/sdk-swift",
            sdkVersion: "1.1.0",
            service: "checkout-ios",
            environment: "production",
            eventType: DebugBundleEventType.logEvent,
            occurredAt: "2026-05-29T10:00:00Z",
            correlation: nil,
            payload: ["message": .string("fixture")],
            device: DebugBundleDeviceContext(),
            releaseChannel: "unknown",
            appVersion: nil,
            buildNumber: nil
        )

        let direct = DebugBundleCapturedBatch(batch: [event])
        XCTAssertEqual(direct.firstEvent(ofType: DebugBundleEventType.logEvent), event)
        XCTAssertNil(direct.firstEvent(ofType: DebugBundleEventType.requestEvent))

        let eventData = try JSONEncoder().encode(event)
        let eventObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: eventData) as? [String: Any]
        )
        for wrapperKey in ["events", "batch"] {
            let data = try JSONSerialization.data(withJSONObject: [wrapperKey: [eventObject]])
            let decoded = try JSONDecoder().decode(DebugBundleCapturedBatch.self, from: data)
            XCTAssertEqual(decoded.batch.count, 1)
            XCTAssertEqual(decoded.batch.first?.eventId, event.eventId)
            XCTAssertEqual(decoded.batch.first?.eventType, event.eventType)
            XCTAssertEqual(decoded.batch.first?.payload["message"], .string("fixture"))
        }
    }
}
