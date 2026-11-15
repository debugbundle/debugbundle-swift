import Foundation
import XCTest
@testable import DebugBundle

final class DebugBundleEvidenceWireTests: XCTestCase {
    func testSharedHookByteBoundaries() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "before-send-budget", withExtension: "json"))
        let budgets = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)).objectValue)
        let original = try JSONDecoder().decode(DebugBundleEventEnvelope.self, from: JSONEncoder().encode(budgets["original"]))
        for raw in try XCTUnwrap(budgets["cases"]?.arrayValue) {
            let fixture = try XCTUnwrap(raw.objectValue)
            let wire = try XCTUnwrap(fixture["event"])
            var candidate = try JSONDecoder().decode(DebugBundleEventEnvelope.self, from: JSONEncoder().encode(wire))
            candidate.payload = try XCTUnwrap(wire.objectValue?["payload"]?.objectValue)
            candidate.context = wire.objectValue?["context"]?.objectValue
            let replacement = candidate
            let result = try XCTUnwrap(applyDebugBundleBeforeSend(original, hook: { _ in replacement }))
            let outcome = fixture["outcome"]?.stringValue
            let id = fixture["id"]?.stringValue ?? ""
            XCTAssertEqual(result.payload["message"], .string(outcome == "fallback" ? "owner removed" : "owner replacement"), id)
            XCTAssertTrue(isValidBeforeSendEvent(result), id)
            if outcome == "fallback" { continue }
            XCTAssertEqual(result.payload["exception_evidence"] != nil, outcome == "keep", id)
            XCTAssertEqual(result.context?["owner_field"], .string("preserved"), id)
            if id.hasSuffix("-legacy") { XCTAssertNotNil(result.context?["evidence_reference"], id) }
            if id.hasSuffix("-typed") && outcome == "reduce" { XCTAssertNil(result.context?["evidence_reference"], id) }
        }
    }

    func testCombinedEvidenceBudgetNeverRestoresOwnerRemovedContent() throws {
        let events = try XCTUnwrap(corpus()["events"]?.arrayValue)
        func event(_ id: String) throws -> DebugBundleEventEnvelope {
            let wire = try XCTUnwrap(events.first { $0.objectValue?["id"]?.stringValue == id }?.objectValue?["event"])
            return try JSONDecoder().decode(DebugBundleEventEnvelope.self, from: JSONEncoder().encode(wire))
        }
        let original = try event("legacy_error")
        var replacement = try event("combined_optional_bytes")
        // Decoding intentionally migrates legacy wire data. A hook authors its
        // payload directly, so restore the exact shared input after decoding.
        replacement.payload = try XCTUnwrap(events.first { $0.objectValue?["id"]?.stringValue == "combined_optional_bytes" }?.objectValue?["event"]?.objectValue?["payload"]?.objectValue)
        replacement.payload["message"] = .string("owner replacement")
        let authored = replacement
        let result = try XCTUnwrap(applyDebugBundleBeforeSend(original, hook: { _ in authored }))
        XCTAssertEqual(result.payload["message"], .string("owner replacement"))
        XCTAssertTrue(isValidBeforeSendEvent(result))
        XCTAssertNil(result.payload["exception_evidence"])
        XCTAssertNotNil(replacement.payload["exception_evidence"])
    }

    private func corpus() throws -> [String: JSONValue] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "evidence-wire-cases", withExtension: "json"))
        return try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)).objectValue)
    }
    func testAllAcceptingEventCasesMatchTheSharedContract() throws {
        for item in try XCTUnwrap(corpus()["events"]?.arrayValue) {
            let fixture = try XCTUnwrap(item.objectValue)
            let event = try XCTUnwrap(fixture["event"])
            let accepted = (try? DebugBundleEvidenceWire.accepts(event)) ?? false
            XCTAssertEqual(accepted, fixture["valid"]?.boolValue, fixture["id"]?.stringValue ?? "unknown fixture")
        }
    }
    func testReceivingJSONBytesMatchIndependentGoldenVectors() throws {
        for item in try XCTUnwrap(corpus()["json_sizes"]?.arrayValue) {
            let fixture = try XCTUnwrap(item.objectValue)
            XCTAssertEqual(DebugBundleAcceptingJSONSize.bytes(try XCTUnwrap(fixture["value"])), fixture["bytes"]?.intValue)
        }
    }
    func testUnrecognizedSchemaKeywordsNeverSilentlyAccept() {
        XCTAssertThrowsError(try DebugBundleCanonicalEventSchema(.object(["unknown_constraint": .bool(true)])))
        XCTAssertFalse((try? DebugBundleCanonicalEventSchema(.bool(false)).accepts(.object([:]))) ?? true)
    }
}
