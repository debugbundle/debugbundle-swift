import Foundation
import XCTest
@testable import DebugBundle

final class DebugBundleInternalDiagnosticsTests: XCTestCase {
    func testProtocolShapedCredentialsAreNotDiagnosticCodes() {
        for reason in ["dbundle_proj_syntheticprivate", "dbundle_mem_syntheticprivate", "dbundle_probe_syntheticprivate"] {
            XCTAssertEqual(DebugBundleInternalDiagnostic.safeReason(reason), "unknown_rejection")
        }
        XCTAssertEqual(DebugBundleInternalDiagnostic.safeReason("invalid_event"), "invalid_event")
        XCTAssertEqual(DebugBundleInternalDiagnostic.safeReason(String(repeating: "a", count: 64)), String(repeating: "a", count: 64))
        XCTAssertEqual(DebugBundleInternalDiagnostic.safeReason(String(repeating: "a", count: 65)), "unknown_rejection")
    }

    func testDiagnosticReasonIsSanitizedAndBounded() async {
        let client = makeIsolatedClient(
            config: DebugBundleConfig(projectToken: "token", service: "audit", batchSize: 10, flushInterval: 60),
            transport: AuditDiagnosticTransport(),
            remoteConfigClient: AuditDiagnosticConfig(),
            connectivityMonitor: AuditDiagnosticConnectivity()
        )
        client.captureMessage("application error", level: .error)
        await client.flush()
        guard case let .string(reason) = client.latestInternalDiagnostic?.metadata["first_reason"] else {
            XCTFail("Expected a diagnostic after terminal rejection")
            return
        }
        XCTAssertFalse(reason.contains("audit-private-value"), "Raw synthetic credential retained")
        XCTAssertLessThanOrEqual(reason.utf8.count, 16_384, "Diagnostic string has no independent bound")
    }
}

private struct AuditDiagnosticTransport: DebugBundleTransporting {
    func send(events: [DebugBundleEventEnvelope], config: DebugBundleConfig) async throws -> DebugBundleTransportResult {
        .init(statusCode: 202, acknowledgement: .init(accepted: 0, rejected: events.count,
            errors: events.indices.map { .init(index: $0, reason: "token=audit-private-value " + String(repeating: "x", count: 65_536)) }))
    }
}
private struct AuditDiagnosticConfig: DebugBundleRemoteConfigClienting {
    func fetch(request: DebugBundleRemoteConfigRequest) async -> DebugBundleRemoteConfigResult { .notModified(eTag: nil) }
}
private final class AuditDiagnosticConnectivity: DebugBundleConnectivityMonitoring {
    var currentStatus: DebugBundleConnectivityStatus { .connected }
    func setUpdateHandler(_ handler: (@Sendable (DebugBundleConnectivityStatus) -> Void)?) {}
}
