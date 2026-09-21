import Foundation
import XCTest
@testable import DebugBundle

final class DebugBundlePrivacyTests: XCTestCase {
    private struct Fixture: Decodable {
        let policy: String
        let cases: [Case]

        struct Case: Decodable {
            let id: String
            let input: JSONValue
            let expected: JSONValue
        }
    }

    func testNativePolicyMatchesPortablePrivacyCases() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/privacy-conformance.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        XCTAssertEqual(fixture.policy, "telemetry-privacy-v1")
        XCTAssertEqual(fixture.cases.count, 24)
        let redactor = DebugBundleRedactor(sensitiveKeys: [])
        for item in fixture.cases {
            XCTAssertEqual(redactor.sanitizeJSON(item.input), item.expected, item.id)
        }
    }

    func testMandatoryFieldsSurviveCustomConfigurationAndOversizedTextIsWithheld() {
        let redactor = DebugBundleRedactor(sensitiveKeys: ["customer_code"])
        XCTAssertEqual(redactor.sanitizeJSON(.object([
            "password": .string("secret"),
            "customer_code": .string("private"),
            "status": .number(503)
        ])), .object([
            "password": .string("[REDACTED]"),
            "customer_code": .string("[REDACTED]"),
            "status": .number(503)
        ]))
        XCTAssertEqual(redactor.sanitize("x".padding(toLength: 4096, withPad: "x", startingAt: 0) + " password=secret"), .string("[REDACTED]"))
    }
}
