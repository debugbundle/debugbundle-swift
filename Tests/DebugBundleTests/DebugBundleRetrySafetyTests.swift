import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DebugBundle

final class DebugBundleRetrySafetyTests: XCTestCase {
    func testHttpRetryHintsAreFiniteAndBounded() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryHintURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for (header, expected) in [("nan", nil), ("inf", nil), ("-inf", nil), ("1e300", 300.0), ("0.25", 0.25),
            ("Wed, 01 Jan 2031 00:00:00 GMT", 300.0),
            ("Wednesday, 01-Jan-31 00:00:00 GMT", 300.0),
            ("Wed Jan  1 00:00:00 2031", 300.0), ("Sun, 06 Nov 1994 08:49:37 GMT", 0.0), ("tomorrow", nil)] {
            RetryHintURLProtocol.header = header
            let result = try await DebugBundleHTTPTransport(session: session).send(
                events: [], config: DebugBundleConfig(projectToken: "token", service: "retry-safety")
            )
            XCTAssertEqual(result.retryAfter, expected, "HTTP retry hint \(header)")
        }
    }

    func testCustomRetryHintsRemainFiniteAndRecover() async {
        for outcome in [429, 503, 202, 203] {
            for hint in [Double.nan, Double.infinity, -Double.infinity, 1e300] {
                var now = Date(timeIntervalSince1970: 1_000)
                let transport = RetrySafetyTransport(hint: hint, outcome: outcome)
                let client = makeIsolatedClient(
                    config: DebugBundleConfig(projectToken: "token", service: "retry-safety"),
                    transport: transport,
                    clock: { now },
                    random: { 0 }
                )
                client.captureMessage("retained", level: .error)
                await client.flush()
                XCTAssertNil(client.lastEventAt)
                await client.flush()
                let immediateCalls = await transport.callCount()
                XCTAssertEqual(immediateCalls, 1, "invalid retry hint \(hint)")
                if hint.isFinite {
                    now = now.addingTimeInterval(299)
                    await client.flush()
                    let earlyCalls = await transport.callCount()
                    XCTAssertEqual(earlyCalls, 1, "outcome \(outcome) must honor the full retry delay")
                }
                now = now.addingTimeInterval(2)
                await client.flush()
                let recoveredCalls = await transport.callCount()
                XCTAssertEqual(recoveredCalls, 2, "retry hint \(hint) must permit recovery")
                XCTAssertNotNil(client.lastEventAt)
            }
        }
    }
}

private final class RetryHintURLProtocol: URLProtocol {
    static var header = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: "HTTP/1.1",
                                       headerFields: ["Retry-After": Self.header])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor RetrySafetyTransport: DebugBundleTransporting {
    private let hint: TimeInterval
    private var calls = 0

    private let outcome: Int
    init(hint: TimeInterval, outcome: Int) { self.hint = hint; self.outcome = outcome }

    func send(events: [DebugBundleEventEnvelope], config: DebugBundleConfig) async throws -> DebugBundleTransportResult {
        calls += 1
        if calls > 1 { return DebugBundleTransportResult(statusCode: 202) }
        return DebugBundleTransportResult(statusCode: outcome, retryAfter: hint,
            acknowledgement: outcome == 203 ? .init(accepted: 0, rejected: 1,
                errors: [.init(index: 0, reason: "rate_limited")]) : nil,
            acknowledgementRequired: outcome == 202)
    }

    func callCount() -> Int { calls }
}
