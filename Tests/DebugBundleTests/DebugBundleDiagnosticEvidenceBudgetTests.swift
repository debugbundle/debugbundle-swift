import Foundation
import XCTest
@testable import DebugBundle

final class DebugBundleDiagnosticEvidenceBudgetTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let scope = DebugBundleEvidenceScope(operationId: "11111111-1111-4111-8111-111111111111")
    private func event(failure: String = "22222222-2222-4222-8222-222222222222", attempt: String = UUID().uuidString.lowercased(), seconds: Double = 0,
        trace: String? = nil, session: String? = nil, service: String = "ios", environment: String = "test") -> DebugBundleEventEnvelope {
        DebugBundleEventEnvelope(sdkName: "@debugbundle/sdk-swift", sdkVersion: "3.0.1", service: service, environment: environment,
            eventType: "diagnostic_context", occurredAt: debugBundleTimestamp(start.addingTimeInterval(seconds)),
            correlation: .init(requestId: nil, traceId: trace, sessionId: session, userIdHash: nil),
            payload: ["version": .number(1), "kind": .string("recovery"), "failure_ref": .string(failure),
                "scope": scope.wire!, "attempt_id": .string(attempt), "state": .string("attempt_started")],
            device: .init(), releaseChannel: "test", appVersion: nil, buildNumber: nil)
    }
    private func primary(_ event: DebugBundleEventEnvelope) -> DebugBundleEventEnvelope {
        var result = event
        result.eventId = UUID().uuidString.lowercased()
        result.eventType = "frontend_exception"
        result.context = ["evidence_reference": .object(["version": .number(1), "failure_ref": event.payload["failure_ref"]!, "scope": event.payload["scope"]!])]
        result.payload = [:]
        return result
    }

    func testAttemptObservationAndWindowAllowancesAreNotRefunded() {
        let budget = DebugBundleDiagnosticBudget()
        let attempt = UUID().uuidString.lowercased()
        for _ in 0..<20 {
            let value = event(attempt: attempt)
            XCTAssertTrue(budget.reserve(value)); XCTAssertTrue(budget.eligible(value)); budget.release(value.eventId)
        }
        XCTAssertFalse(budget.reserve(event(attempt: attempt)))
        let attempts = DebugBundleDiagnosticBudget()
        for _ in 0..<5 { let value = event(); XCTAssertTrue(attempts.reserve(value)); attempts.release(value.eventId) }
        XCTAssertFalse(attempts.reserve(event()))
        let windows = DebugBundleDiagnosticBudget()
        for _ in 0..<50 { let value = event(failure: UUID().uuidString.lowercased()); XCTAssertTrue(windows.reserve(value)); windows.release(value.eventId) }
        XCTAssertFalse(windows.reserve(event(failure: UUID().uuidString.lowercased())))
        XCTAssertTrue(windows.reserve(event(failure: UUID().uuidString.lowercased(), seconds: 301)))
    }

    func testPendingMetadataSharesByteBudgetAndOfflineReceiptsCannotRenewWindow() {
        let budget = DebugBundleDiagnosticBudget()
        let old = event()
        XCTAssertTrue(budget.reserve(old))
        budget.restore([old])
        XCTAssertFalse(budget.reserve(event(seconds: 301)))
        var oversized = event(failure: UUID().uuidString.lowercased())
        oversized.context = ["value": .string(String(repeating: "x", count: 65_536))]
        XCTAssertFalse(budget.reserve(oversized))
        var retained: [DebugBundleEventEnvelope] = []
        for _ in 0..<100 {
            var value = event(failure: UUID().uuidString.lowercased())
            value.context = ["value": .string(String(repeating: "x", count: 2048))]
            if budget.reserve(value) { retained.append(value) }
        }
        XCTAssertLessThan(retained.count, 30)
        XCTAssertGreaterThan(retained.count, 5)
        budget.clear()
        XCTAssertTrue(budget.reserve(event()))
    }

    func testIdentityReplacementPersistenceAndAmbiguousFailuresRemainOwned() {
        let budget = DebugBundleDiagnosticBudget()
        let original = event()
        XCTAssertTrue(budget.reserve(original))
        var replacement = original; replacement.eventId = UUID().uuidString.lowercased()
        XCTAssertTrue(budget.replace(original.eventId, with: replacement))
        XCTAssertFalse(budget.eligible(original)); XCTAssertTrue(budget.eligible(replacement))
        budget.persisted(prepared: [replacement], retained: [replacement])
        budget.synchronize([])
        XCTAssertFalse(budget.eligible(replacement))
        let first = primary(original)
        XCTAssertTrue(budget.register(first))
        var other = first; other.eventId = UUID().uuidString.lowercased()
        XCTAssertFalse(budget.register(other))
        XCTAssertFalse(budget.reserve(event()))
        XCTAssertFalse(budget.replace(nil, with: event()))
    }

    func testScopeIdentityIncludesServiceEnvironmentTraceAndSessionZero() {
        let budget = DebugBundleDiagnosticBudget()
        let first = primary(event(trace: nil, session: "0"))
        XCTAssertTrue(budget.register(first))
        XCTAssertFalse(budget.register(primary(event(trace: nil, session: "0"))))
        XCTAssertTrue(budget.reserve(event(trace: "trace", session: "0")))
        XCTAssertTrue(budget.reserve(event(trace: nil, session: "other")))
        XCTAssertTrue(budget.reserve(event(trace: nil, session: "0", service: "other")))
        XCTAssertTrue(budget.reserve(event(trace: nil, session: "0", environment: "other")))
        XCTAssertFalse(budget.reserve(event(trace: nil, session: "0")))
        var invalid = event(); invalid.payload["failure_ref"] = .string("not-fresh")
        XCTAssertFalse(budget.reserve(invalid))
    }
}
