import Foundation
import XCTest
import DebugBundleTestSupport
@testable import DebugBundle

final class DebugBundleEvidenceCapabilityTests: XCTestCase {
    private func graph() throws -> JSONValue {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "evidence-wire-cases", withExtension: "json"))
        let corpus = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        return try XCTUnwrap(corpus.objectValue?["events"]?.arrayValue?.first?.objectValue?["event"]?.objectValue?["payload"]?.objectValue?["exception_evidence"])
    }

    func testDescriptorIsClosedOrderedBoundedAndIntersectsEveryHop() throws {
        let all = DebugBundleEvidenceCapabilities(features: Array(DebugBundleEvidenceCapabilities.known.reversed()))
        XCTAssertEqual(all.features, DebugBundleEvidenceCapabilities.known)
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(all))
        XCTAssertEqual(encoded, all.wire)
        for raw in [JSONValue.null, .object([:]), .object(["version": .number(2), "features": .array([])]),
            .object(["version": .number(1), "features": .array([.string("unknown")])]),
            .object(["version": .number(1), "features": .array([.number(1)])]),
            .object(["version": .number(1), "features": .array([]), "extra": .bool(true)])] {
            XCTAssertTrue(DebugBundleEvidenceCapabilities.normalize(raw).features.isEmpty)
            let decoded = try JSONDecoder().decode(DebugBundleEvidenceCapabilities.self, from: JSONEncoder().encode(raw))
            XCTAssertTrue(decoded.features.isEmpty)
        }
        XCTAssertTrue(DebugBundleEvidenceCapabilities(features: ["recovery_v1", "recovery_v1"]).features.isEmpty)
        XCTAssertTrue(DebugBundleEvidenceCapabilities(version: 2, features: all.features).features.isEmpty)
        let recovery = DebugBundleEvidenceCapabilities(features: ["recovery_v1"])
        XCTAssertEqual(DebugBundleEvidenceCapabilities.intersect([all, recovery]), recovery)
        XCTAssertEqual(DebugBundleEvidenceCapabilities.intersect(Array(repeating: all, count: 8)), all)
        XCTAssertTrue(DebugBundleEvidenceCapabilities.intersect([]).features.isEmpty)
        XCTAssertTrue(DebugBundleEvidenceCapabilities.intersect(Array(repeating: all, count: 9)).features.isEmpty)
        XCTAssertTrue(DebugBundleEvidenceCapabilities.intersect([all, .init()]).features.isEmpty)
    }

    func testProofRevocationLocalFlagsAndTypedReferenceDowngrade() throws {
        let all = DebugBundleEvidenceCapabilities(features: DebugBundleEvidenceCapabilities.known)
        let options = DebugBundleEvidenceOptions(evidenceCapabilities: all)
        let controller = DebugBundleEvidenceController(options)
        XCTAssertTrue(controller.canCaptureExceptions)
        controller.observe(nil)
        XCTAssertFalse(controller.canCaptureExceptions)
        controller.observe(all.wire)
        XCTAssertTrue(controller.canCaptureExceptions)
        let disabled = DebugBundleEvidenceController(.init(captureExceptionEvidence: false, evidenceCapabilities: all))
        XCTAssertFalse(disabled.canCaptureExceptions)
        let config = DebugBundleConfig(projectToken: "fictional").withEvidenceOptions(options)
        XCTAssertEqual(config.evidenceOptions, options)
        for path in ["https://example.invalid/v1/events", "https://example.invalid/prefix/v1/events"] {
            XCTAssertTrue(DebugBundleEvidenceController.matchingConfigPath(try XCTUnwrap(URL(string: path))))
        }
        for path in ["https://example.invalid/relay", "https://example.invalid/v1/events?relay=1", "https://user@example.invalid/v1/events", "file:///v1/events"] {
            XCTAssertFalse(DebugBundleEvidenceController.matchingConfigPath(try XCTUnwrap(URL(string: path))))
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "evidence-wire-cases", withExtension: "json"))
        let corpus = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let raw = try XCTUnwrap(corpus.objectValue?["events"]?.arrayValue?.first?.objectValue?["event"])
        var event = try JSONDecoder().decode(DebugBundleEventEnvelope.self, from: JSONEncoder().encode(raw))
        event.context = ["evidence_reference": .object(["version": .number(1),
            "failure_ref": .string("11111111-1111-4111-8111-111111111111"),
            "scope": .object(["kind": .string("operation"), "operation_id": .string("22222222-2222-4222-8222-222222222222")])])]
        XCTAssertNotNil(controller.filter(event, diagnosticsAllowed: true)?.context?["evidence_reference"])
        XCTAssertNil(controller.filter(event, diagnosticsAllowed: false)?.context?["evidence_reference"])
        XCTAssertNil(disabled.filter(event, diagnosticsAllowed: true)?.payload["exception_evidence"])
        event.eventType = "diagnostic_context"
        XCTAssertNil(controller.filter(event, diagnosticsAllowed: true))
    }

    func testUnprovenOpaquePathStripsHookEvidenceAndKeepsOriginalFailure() async throws {
        let graph = try graph()
        let transport = RecordingTransport()
        let client = makeIsolatedClient(config: DebugBundleConfig(projectToken: "token", service: "ios", batchSize: 10,
            flushInterval: 60, beforeSend: { input in
                var event = input
                event.payload["exception_evidence"] = graph
                event.context = ["evidence_reference": .string("legacy-owner-value")]
                return event
            }), transport: transport, random: { 0 })
        client.captureException(NSError(domain: "fictional", code: 1, userInfo: [NSLocalizedDescriptionKey: "original failure"]))
        await client.flush()
        let event = await transport.recordedBatches().flatMap { $0 }.first
        XCTAssertEqual(event?.payload["message"], .string("original failure"))
        XCTAssertNil(event?.payload["exception_evidence"])
        XCTAssertEqual(event?.context?["evidence_reference"], .string("legacy-owner-value"))
    }
}
