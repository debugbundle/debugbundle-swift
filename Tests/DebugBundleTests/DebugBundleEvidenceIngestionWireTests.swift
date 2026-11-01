import Foundation
import XCTest
@testable import DebugBundle

final class DebugBundleEvidenceIngestionWireTests: XCTestCase {
    private func original() throws -> DebugBundleEventEnvelope {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "evidence-wire-cases", withExtension: "json"))
        let corpus = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let raw = try XCTUnwrap(corpus.objectValue?["events"]?.arrayValue?.first?.objectValue?["event"])
        return try JSONDecoder().decode(DebugBundleEventEnvelope.self, from: JSONEncoder().encode(raw))
    }
    func testOptionalReductionPreservesLatestPrimaryIdentityAndLegacyReference() throws {
        var event = try original()
        event.eventId = UUID().uuidString.lowercased()
        event.payload["message"] = .string("latest accepted hook failure")
        event.context = ["evidence_reference": .string("legacy owner value")]
        event.payload["stack"] = .string("x")
        XCTAssertTrue(isValidBeforeSendEvent(event))
        let overhead = try JSONEncoder().encode(event).count - 1
        event.payload["stack"] = .string(String(repeating: "x", count: 262_144 - 13 - overhead + 100))
        let fitted = try XCTUnwrap(DebugBundleIngestionWire.fit(event))
        XCTAssertEqual(fitted.eventId, event.eventId)
        XCTAssertEqual(fitted.payload["message"], .string("latest accepted hook failure"))
        XCTAssertNil(fitted.payload["exception_evidence"])
        XCTAssertEqual(fitted.context?["evidence_reference"], .string("legacy owner value"))
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(DebugBundleBatchRequest(events: [fitted])).count, 262_144)
        event.payload["stack"] = .string(String(repeating: "x", count: 262_144))
        XCTAssertTrue(DebugBundleIngestionWire.fit(event) == nil)
        event.eventType = "log_event"
        event.payload = ["level": .string("error"), "message": .string(String(repeating: "x", count: 262_144)), "attributes": .object([:])]
        XCTAssertTrue(isValidBeforeSendEvent(event))
        XCTAssertTrue(DebugBundleIngestionWire.fit(event) == nil)
    }
    func testExactWrapperBytesAndNativeEventCountLimit() throws {
        let event = try original()
        let events = Array(repeating: event, count: 101)
        XCTAssertEqual(DebugBundleIngestionWire.prefixCount(events), 100)
        XCTAssertEqual(DebugBundleIngestionWire.prefixCount([]), 0)
        var large = event
        large.payload["stack"] = .string(String(repeating: "x", count: 262_144))
        XCTAssertEqual(DebugBundleIngestionWire.prefixCount([large]), 0)
    }
}
