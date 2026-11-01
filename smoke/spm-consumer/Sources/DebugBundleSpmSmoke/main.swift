import DebugBundle
import DebugBundleSwiftLog
import Foundation

@main
struct DebugBundleSpmSmoke {
    static func main() async throws {
        var logMessage: String?
        var logLabel: String?
        let handler = DebugBundleLogHandler(label: "installed-adapter") { _, message, context in
            logMessage = message
            logLabel = context["logger_label"] as? String
        }
        handler.log(level: .warning, message: "installed adapter", metadata: nil,
            source: "smoke", file: "smoke.swift", function: "main", line: 1)
        guard logMessage == "installed adapter", logLabel == "installed-adapter" else {
            throw SmokeFailure("the installed SwiftLog compatibility method did not emit")
        }
        guard
            let endpointValue = ProcessInfo.processInfo.environment["DEBUGBUNDLE_SMOKE_ENDPOINT"],
            let endpoint = URL(string: endpointValue)
        else {
            throw SmokeFailure("DEBUGBUNDLE_SMOKE_ENDPOINT is required")
        }

        let traceID = "11111111111111111111111111111111"
        let queueURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("debugbundle-swift-spm-smoke-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: queueURL)
        }

        let client = DebugBundle.initialize(
            DebugBundleConfig(
                projectToken: "dbundle_proj_swift_smoke",
                environment: "smoke",
                service: "swift-spm-smoke",
                endpoint: endpoint,
                batchSize: 25,
                flushInterval: 60,
                requestTimeout: 5,
                offlineQueueURL: queueURL
            ).withEvidenceOptions(.init(captureRecoveryObservations: true)),
            transport: DebugBundleHTTPTransport()
        )

        await client.refreshRemoteConfig()
        let scope = client.beginOperation()
        let failureRef = UUID().uuidString.lowercased()
        var context = DebugBundleEvidenceContext.forFailure(failureRef, scope: scope.evidenceScope)
        context["trace_id"] = traceID
        let original = NSError(domain: "smoke", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "clean SPM consumer exception",
            NSUnderlyingErrorKey: NSError(domain: "cause", code: 2, userInfo: [NSLocalizedDescriptionKey: "Authorization: Bearer smoke-private-token"])
        ])
        defer { withExtendedLifetime(original) {} }
        client.captureException(original, context: context)
        client.captureRecovery(.init(failureRef: failureRef, attemptId: UUID().uuidString.lowercased(),
            state: "attempt_completed", scope: scope.evidenceScope, statusCode: 200, traceId: traceID))
        scope.close()
        client.captureRequest(
            DebugBundleRequestInfo(
                method: "GET",
                url: "https://example.test/smoke?mode=artifact",
                traceId: traceID
            ),
            response: DebugBundleResponseInfo(statusCode: 503, durationMillis: 25)
        )
        await client.flush()

        guard client.status == .healthy, client.lastEventAt != nil else {
            throw SmokeFailure("the staged SPM package did not acknowledge delivery")
        }

        print("Clean SPM consumer delivered and acknowledged exception, request and explicit recovery events.")
    }
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
