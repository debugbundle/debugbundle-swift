import Foundation
import XCTest
@testable import DebugBundle

final class DebugBundleEvidenceWireTests: XCTestCase {
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
