import Foundation
import XCTest
import DebugBundleTestSupport
@testable import DebugBundle

final class DebugBundleEvidenceEnvelopeTests: XCTestCase {
    private func original() throws -> DebugBundleEventEnvelope {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "evidence-wire-cases", withExtension: "json"))
        let corpus = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let raw = try XCTUnwrap(corpus.objectValue?["events"]?.arrayValue?.first?.objectValue?["event"])
        var event = try JSONDecoder().decode(DebugBundleEventEnvelope.self, from: JSONEncoder().encode(raw))
        event.sdkName = "@debugbundle/sdk-swift"
        event.payload = canonicalizeSwiftEvent(eventType: event.eventType, payload: event.payload, device: event.device, occurredAt: event.occurredAt).payload
        event.payload["exception_evidence"] = raw.objectValue?["payload"]?.objectValue?["exception_evidence"]
        return event
    }

    func testBothExceptionKindsSurviveSessionSamplingAndBackendHookRetainsPriority() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "evidence-wire-cases", withExtension: "json"))
        let corpus = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let backend = try XCTUnwrap(corpus.objectValue?["events"]?.arrayValue?.first {
            $0.objectValue?["valid"] == .bool(true) && $0.objectValue?["event"]?.objectValue?["event_type"] == .string("backend_exception")
        }?.objectValue?["event"]?.objectValue?["payload"]?.objectValue)
        for replacement in [false, true] {
            let transport = RecordingTransport()
            let config = DebugBundleConfig(projectToken: "token", service: "ios", batchSize: 10, flushInterval: 60,
                sessionSampleRate: 0, beforeSend: { input in
                    guard replacement else { return input }
                    var event = input
                    event.eventId = "11111111-1111-4111-8111-111111111111"
                    event.eventType = "backend_exception"
                    event.payload = backend
                    return event
                })
            let client = makeIsolatedClient(config: config, transport: transport, random: { 0.5 })
            client.captureLog("sampled out", level: .error)
            client.captureException(NSError(domain: "fictional", code: 1))
            await client.flush()
            let events = await transport.recordedBatches().flatMap { $0 }
            XCTAssertEqual(events.count, 1)
            if let event = events.first {
                XCTAssertEqual(event.eventType, replacement ? "backend_exception" : "frontend_exception")
                XCTAssertEqual(DebugBundleDeliveryQueue.priority(event), 3)
            }
        }
    }

    func testCanonicalStructuredEvidenceIsValidAndSurvivesSerialization() throws {
        let event = try original()
        XCTAssertTrue(isValidBeforeSendEvent(event))
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(encoded.objectValue?["payload"]?.objectValue?["exception_evidence"], event.payload["exception_evidence"])
    }

    func testValidHookCanChangeIdentityAndKindToStandaloneRecovery() throws {
        let event = try original()
        let id = UUID().uuidString.lowercased()
        let result = applyDebugBundleBeforeSend(event, hook: { input in
            var replacement = input
            replacement.eventId = id
            replacement.eventType = "diagnostic_context"
            replacement.payload = ["version": .number(1), "kind": .string("recovery"),
                "failure_ref": .string("11111111-1111-4111-8111-111111111111"),
                "scope": .object(["kind": .string("operation"), "operation_id": .string("22222222-2222-4222-8222-222222222222")]),
                "attempt_id": .string("33333333-3333-4333-8333-333333333333"), "state": .string("recovery_observed")]
            return replacement
        })
        XCTAssertEqual(result?.eventId, id)
        XCTAssertEqual(result?.eventType, "diagnostic_context")
    }

    func testInvalidHookRetainsProtectedOriginalWhileExhaustedValidationWithholds() throws {
        let event = try original()
        let invalid = applyDebugBundleBeforeSend(event, hook: { input in
            var changed = input
            changed.payload["unexpected"] = .bool(true)
            return changed
        })
        XCTAssertEqual(invalid?.eventId, event.eventId)
        let exhausted = applyDebugBundleBeforeSend(event, hook: { input in
            var changed = input
            changed.context = ["detail": .string(String(repeating: "x", count: 9 * 1024 * 1024))]
            return changed
        })
        XCTAssertTrue(exhausted == nil, "Exhausted native validation must not restore a pre-hook event")
    }
    func testTypedPageSessionZeroAndOtherCorrelationFieldsSurvivePrivacyAndEncoding() throws {
        var event = try original()
        event.eventType = "diagnostic_context"
        event.payload = ["version": .number(1), "kind": .string("recovery"),
            "failure_ref": .string("11111111-1111-4111-8111-111111111111"),
            "scope": .object(["kind": .string("page"), "page_id": .string("22222222-2222-4222-8222-222222222222")]),
            "attempt_id": .string("33333333-3333-4333-8333-333333333333"), "state": .string("attempt_completed")]
        event.correlation = DebugBundleCorrelation(requestId: "request", traceId: "trace", sessionId: "0", userIdHash: "opaque-user-hash")
        XCTAssertTrue(isValidBeforeSendEvent(event))
        let protected = try XCTUnwrap(protectDebugBundleEvent(event, redactor: DebugBundleRedactor(sensitiveKeys: DebugBundleConfig.defaultRedactFields)))
        let decoded = try JSONDecoder().decode(DebugBundleEventEnvelope.self, from: JSONEncoder().encode(protected))
        XCTAssertEqual(decoded.correlation, event.correlation)
        event.correlation?.sessionId = "dbundle_proj_FICTIONAL_SECRET"
        XCTAssertTrue(protectDebugBundleEvent(event, redactor: DebugBundleRedactor(sensitiveKeys: DebugBundleConfig.defaultRedactFields)) == nil)
    }

}
