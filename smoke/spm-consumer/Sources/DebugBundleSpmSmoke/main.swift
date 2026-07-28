import DebugBundle
import Foundation

@main
struct DebugBundleSpmSmoke {
    static func main() async throws {
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
            ),
            transport: DebugBundleHTTPTransport()
        )

        client.captureException(
            SmokeFailure("clean SPM consumer exception"),
            context: ["trace_id": traceID]
        )
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

        print("Clean SPM consumer delivered and acknowledged exception and request events.")
    }
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
