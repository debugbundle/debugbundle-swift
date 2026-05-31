import Foundation
import XCTest
@testable import DebugBundle
import Alamofire
@testable import DebugBundleAlamofire
import DebugBundleURLSession
import DebugBundleTestSupport

final class DebugBundleQueueAndTransportTests: XCTestCase {
    func testFileQueuePersistsAndReloadsBufferedEvents() async throws {
        let queueURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json")
        let transport = RecordingTransport()

        let firstClient = DebugBundleClient(
            config: DebugBundleConfig(
                projectToken: "token",
                service: "checkout-ios",
                offlineQueueURL: queueURL
            ),
            transport: transport,
            random: { 0 }
        )

        firstClient.captureMessage("persist me", level: .error)

        let persistedEvents = try DebugBundleQueueInspector.loadEvents(from: queueURL)
        XCTAssertEqual(persistedEvents.count, 1)
        XCTAssertEqual(persistedEvents.first?.payload["message"], .string("persist me"))

        let secondClient = DebugBundleClient(
            config: DebugBundleConfig(
                projectToken: "token",
                service: "checkout-ios",
                offlineQueueURL: queueURL
            ),
            transport: transport,
            random: { 0 }
        )

        await secondClient.flush()

        let batches = await transport.recordedBatches()
        XCTAssertEqual(batches.first?.first?.payload["message"], .string("persist me"))
    }

    func testConnectivityMonitorDefersFlushUntilReachable() async throws {
        let transport = RecordingTransport()
        let monitor = TestConnectivityMonitor(status: .disconnected)
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios"),
            transport: transport,
            remoteConfigClient: StaticRemoteConfigClient(result: .notModified(eTag: nil)),
            connectivityMonitor: monitor,
            random: { 0 }
        )

        client.captureMessage("queued while offline", level: .error)
        await client.flush()

        XCTAssertEqual(client.status, .degraded)
        let offlineBatches = await transport.recordedBatches()
        XCTAssertEqual(offlineBatches.count, 0)

        monitor.update(.connected)
        let recordedBatchCount = await waitForRecordedBatchCount(on: transport, minimum: 1)
        XCTAssertEqual(recordedBatchCount, 1)

        let batches = await transport.recordedBatches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.first?.payload["message"], .string("queued while offline"))
    }

    func testFlushHonorsRetryAfterWindowBeforeRetrying429() async {
        let transport = SequencedTransport(results: [
            .success(DebugBundleTransportResult(statusCode: 429, retryAfter: 120)),
            .success(DebugBundleTransportResult(statusCode: 202))
        ])
        var currentTime = Date(timeIntervalSince1970: 1_000)

        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios"),
            transport: transport,
            remoteConfigClient: StaticRemoteConfigClient(result: .notModified(eTag: nil)),
            clock: { currentTime },
            random: { 0 }
        )

        client.captureMessage("retry-after-message", level: .error)

        await client.flush()
        let firstRetryAfterCallCount = await transport.sendCallCount()
        XCTAssertEqual(firstRetryAfterCallCount, 1)

        await client.flush()
        let suppressedRetryAfterCallCount = await transport.sendCallCount()
        XCTAssertEqual(suppressedRetryAfterCallCount, 1)
        XCTAssertEqual(client.status, .degraded)

        currentTime = currentTime.addingTimeInterval(120)
        await client.flush()

        let finalRetryAfterCallCount = await transport.sendCallCount()
        XCTAssertEqual(finalRetryAfterCallCount, 2)
        XCTAssertEqual(client.status, .healthy)
    }

    func testFlushBacksOffTransient5xxWithoutRetryAfter() async {
        let transport = SequencedTransport(results: [
            .success(DebugBundleTransportResult(statusCode: 503)),
            .success(DebugBundleTransportResult(statusCode: 202))
        ])
        var currentTime = Date(timeIntervalSince1970: 2_000)

        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios"),
            transport: transport,
            remoteConfigClient: StaticRemoteConfigClient(result: .notModified(eTag: nil)),
            clock: { currentTime },
            random: { 0 }
        )

        client.captureMessage("server-error-message", level: .error)

        await client.flush()
        let firstFiveHundredCallCount = await transport.sendCallCount()
        XCTAssertEqual(firstFiveHundredCallCount, 1)

        await client.flush()
        let suppressedFiveHundredCallCount = await transport.sendCallCount()
        XCTAssertEqual(suppressedFiveHundredCallCount, 1)

        currentTime = currentTime.addingTimeInterval(1)
        await client.flush()

        let finalFiveHundredCallCount = await transport.sendCallCount()
        XCTAssertEqual(finalFiveHundredCallCount, 2)
        XCTAssertEqual(client.status, .healthy)
    }

    func testNonRetryableClientErrorDropsQueueAndRecordsInternalDiagnostic() async {
        let queueURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("queue.json")
        let transport = SequencedTransport(results: [.success(DebugBundleTransportResult(statusCode: 400))])
        let monitor = TestConnectivityMonitor(status: .connected)
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios", offlineQueueURL: queueURL),
            transport: transport,
            remoteConfigClient: StaticRemoteConfigClient(result: .notModified(eTag: nil)),
            connectivityMonitor: monitor,
            random: { 0 }
        )

        client.captureMessage("drop-on-400", level: .error)

        let persistedBeforeFlush = try? DebugBundleQueueInspector.loadEvents(from: queueURL)
        XCTAssertEqual(persistedBeforeFlush?.count, 1)

        await client.flush()

        let persistedAfterFlush = try? DebugBundleQueueInspector.loadEvents(from: queueURL)
        XCTAssertEqual(persistedAfterFlush?.count, 0)
        XCTAssertEqual(client.status, .disconnected)

        let diagnostic = client.latestInternalDiagnostic
        XCTAssertEqual(diagnostic?.category, "transport_drop")
        XCTAssertEqual(diagnostic?.metadata["status_code"], .number(400))
        XCTAssertEqual(diagnostic?.metadata["dropped_event_count"], .number(1))
    }

    func testBatchSizeTriggersFlushWithoutExplicitCall() async {
        let transport = SequencedTransport(results: [.success(DebugBundleTransportResult(statusCode: 202))])
        let sleeper = TestSleeper()
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios", batchSize: 1, flushInterval: 60),
            transport: transport,
            remoteConfigClient: StaticRemoteConfigClient(result: .notModified(eTag: nil)),
            sleep: { interval in
                await sleeper.wait(interval: interval)
            },
            random: { 0 }
        )

        client.captureMessage("flush-on-batch", level: .error)

        let sendCallCount = await waitForSendCallCount(on: transport, minimum: 1)
        XCTAssertEqual(sendCallCount, 1)
        XCTAssertEqual(client.status, .healthy)
    }

    func testFlushCapsTransportBatchSizeAndDrainsRemainingEventsOnNextFlush() async {
        let transport = RecordingTransport()
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios", batchSize: 2, flushInterval: 60),
            transport: transport,
            remoteConfigClient: StaticRemoteConfigClient(result: .notModified(eTag: nil)),
            random: { 0 }
        )

        client.captureMessage("first", level: .error)
        client.captureMessage("second", level: .error)
        client.captureMessage("third", level: .error)

        await Task.yield()
        await Task.yield()
        await client.flush()

        let recordedBatchCount = await waitForRecordedBatchCount(on: transport, minimum: 2)
        XCTAssertEqual(recordedBatchCount, 2)

        let batches = await transport.recordedBatches()
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches.map(\.count).sorted(), [1, 2])

        let deliveredMessages = batches.flatMap { batch in
            batch.compactMap { envelope -> String? in
                guard case let .string(message)? = envelope.payload["message"] else {
                    return nil
                }
                return message
            }
        }
        XCTAssertEqual(deliveredMessages, ["first", "second", "third"])
    }

    func testFlushIntervalTriggersPeriodicFlushWithoutExplicitCall() async {
        let transport = SequencedTransport(results: [.success(DebugBundleTransportResult(statusCode: 202))])
        let sleeper = TestSleeper()
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios", batchSize: 10, flushInterval: 60),
            transport: transport,
            remoteConfigClient: StaticRemoteConfigClient(result: .notModified(eTag: nil)),
            sleep: { interval in
                await sleeper.wait(interval: interval)
            },
            random: { 0 }
        )

        client.captureMessage("flush-on-interval", level: .error)

        let preTickCallCount = await transport.sendCallCount()
        XCTAssertEqual(preTickCallCount, 0)

        await sleeper.waitUntilHasWaiter()
        await sleeper.advanceOneTick()
        let postTickCallCount = await waitForSendCallCount(on: transport, minimum: 1)
        XCTAssertEqual(postTickCallCount, 1)
        XCTAssertEqual(client.status, .healthy)
    }

    func testAppBackgroundTriggersFlushWithoutExplicitCall() async {
        let transport = SequencedTransport(results: [.success(DebugBundleTransportResult(statusCode: 202))])
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios", batchSize: 10, flushInterval: 60),
            transport: transport,
            remoteConfigClient: StaticRemoteConfigClient(result: .notModified(eTag: nil)),
            random: { 0 }
        )

        client.captureMessage("flush-on-background", level: .error)
        client.recordAppBackground()

        let sendCallCount = await waitForSendCallCount(on: transport, minimum: 1)
        XCTAssertEqual(sendCallCount, 1)
        XCTAssertEqual(client.status, .healthy)
    }

    func testHttpTransportSendsCanonicalBatchAndCapsRetryAfter() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let transport = DebugBundleHTTPTransport(session: session)

        let event = DebugBundleEventEnvelope(
            sdkName: "@debugbundle/sdk-swift",
            sdkVersion: "1.0.0",
            service: "checkout-ios",
            environment: "production",
            eventType: DebugBundleEventType.logEvent,
            occurredAt: "2026-05-29T10:00:00Z",
            correlation: DebugBundleCorrelation(traceId: "trace-123"),
            payload: ["message": .string("hello")],
            device: DebugBundleDeviceContext(osName: "iOS"),
            releaseChannel: "app-store",
            appVersion: "1.2.3",
            buildNumber: "42"
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.debugbundle.com/v1/events")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")

            let body = try XCTUnwrap(request.httpBody ?? readBody(from: request.httpBodyStream))
            let decoded = try JSONDecoder().decode(DebugBundleBatchRequest.self, from: body)
            XCTAssertEqual(decoded.batch.count, 1)
            XCTAssertEqual(decoded.batch.first?.payload["message"], .string("hello"))

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "600"]
            )!
            return (response, Data())
        }

        let result = try await transport.send(
            events: [event],
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios")
        )

        XCTAssertEqual(result.statusCode, 429)
        XCTAssertEqual(result.retryAfter, 300)
    }

    func testRemoteConfigFetchRewritesEventsEndpointPreservingPrefixAndQuery() async {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let client = DebugBundleHTTPRemoteConfigClient(session: session)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://proxy.example.com/runtime/v1/sdk/config?tenant=acme"
            )
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["ETag": "etag-123"]
            )!
            let data = try JSONEncoder().encode(
                DebugBundleRemoteConfigResponse(
                    probesEnabled: true,
                    remoteProbesEnabled: false,
                    activeProbes: [],
                    pollIntervalMillis: 15_000
                )
            )
            return (response, data)
        }

        let result = await client.fetch(
            request: DebugBundleRemoteConfigRequest(
                projectToken: "token",
                endpoint: URL(string: "https://proxy.example.com/runtime/v1/events?tenant=acme")!,
                timeout: 5
            )
        )

        XCTAssertEqual(
            result,
            .loaded(
                DebugBundleRemoteConfigResponse(
                    probesEnabled: true,
                    remoteProbesEnabled: false,
                    activeProbes: [],
                    pollIntervalMillis: 15_000
                ),
                eTag: "etag-123"
            )
        )
    }

    func testRemoteConfigFetchAppendsSDKConfigForCustomEndpointPreservingQuery() async {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let client = DebugBundleHTTPRemoteConfigClient(session: session)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://proxy.example.com/runtime/ingest/sdk/config?tenant=acme"
            )

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 304,
                httpVersion: nil,
                headerFields: ["ETag": "etag-456"]
            )!
            return (response, Data())
        }

        let result = await client.fetch(
            request: DebugBundleRemoteConfigRequest(
                projectToken: "token",
                endpoint: URL(string: "https://proxy.example.com/runtime/ingest?tenant=acme")!,
                timeout: 5,
                eTag: "etag-123"
            )
        )

        XCTAssertEqual(result, .notModified(eTag: "etag-456"))
    }

    func testMockIngestionServerCapturesRealTransportRequest() async throws {
        let server = try DebugBundleMockIngestionServer()
        try await server.start()
        defer {
            Task {
                await server.stop()
            }
        }

        let transport = DebugBundleHTTPTransport()
        let event = DebugBundleEventEnvelope(
            sdkName: "@debugbundle/sdk-swift",
            sdkVersion: "1.0.0",
            service: "checkout-ios",
            environment: "production",
            eventType: DebugBundleEventType.logEvent,
            occurredAt: "2026-05-29T10:00:00Z",
            correlation: DebugBundleCorrelation(traceId: "trace-abc"),
            payload: ["message": .string("hello-localhost")],
            device: DebugBundleDeviceContext(osName: "iOS"),
            releaseChannel: "app-store",
            appVersion: "1.2.3",
            buildNumber: "42"
        )

        let endpointURL = await server.endpointURL()
        let endpoint = try XCTUnwrap(endpointURL)
        let result = try await transport.send(
            events: [event],
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios", endpoint: endpoint)
        )

        let requests = await server.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/events")
        XCTAssertEqual(request.headers["authorization"], "Bearer token")

        let decoded = try request.decodeBatch()
        XCTAssertEqual(decoded.batch.count, 1)
        XCTAssertEqual(decoded.batch.first?.payload["message"], .string("hello-localhost"))
        XCTAssertEqual(result.statusCode, 202)
    }

    func testURLRequestInstrumentationAddsTraceHeaderOnlyForAllowedTargets() {
        let allowedRequest = URLRequest(url: URL(string: "https://api.example.com/checkout")!)
        let blockedRequest = URLRequest(url: URL(string: "https://third-party.example.com/pixel")!)

        let instrumentedAllowed = allowedRequest.debugBundleInstrumented(
            tracePropagationTargets: [.host("api.example.com")],
            traceID: "trace-123"
        )
        let instrumentedBlocked = blockedRequest.debugBundleInstrumented(
            tracePropagationTargets: [.host("api.example.com")],
            traceID: "trace-123"
        )

        XCTAssertEqual(instrumentedAllowed.value(forHTTPHeaderField: DebugBundleURLSessionInstrumentation.traceHeaderName), "trace-123")
        XCTAssertNil(instrumentedBlocked.value(forHTTPHeaderField: DebugBundleURLSessionInstrumentation.traceHeaderName))
    }

    func testAlamofireInterceptorAddsTraceHeaderOnlyForAllowedTargets() async throws {
        let interceptor = DebugBundleAlamofireInterceptor(
            tracePropagationTargets: [.host("api.example.com")],
            traceIDProvider: { "trace-123" }
        )
        let session = Session(configuration: .ephemeral)
        let allowedRequest = URLRequest(url: URL(string: "https://api.example.com/checkout")!)
        let blockedRequest = URLRequest(url: URL(string: "https://third-party.example.com/pixel")!)

        let adaptedAllowed = try await adaptRequest(allowedRequest, using: interceptor, session: session)
        let adaptedBlocked = try await adaptRequest(blockedRequest, using: interceptor, session: session)

        XCTAssertEqual(adaptedAllowed.value(forHTTPHeaderField: DebugBundleURLSessionInstrumentation.traceHeaderName), "trace-123")
        XCTAssertNil(adaptedBlocked.value(forHTTPHeaderField: DebugBundleURLSessionInstrumentation.traceHeaderName))
    }

    func testInstrumentedURLSessionInjectsTraceHeaderAndRecordsRequestEvent() async throws {
        let transport = RecordingTransport()
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios"),
            transport: transport,
            remoteConfigClient: StaticRemoteConfigClient(
                result: .loaded(
                    DebugBundleRemoteConfigResponse(
                        capturePolicy: DebugBundleRemoteCapturePolicy(
                            preset: "balanced",
                            captureLogs: "warning",
                            captureRequestEvents: "failures_only",
                            captureBreadcrumbs: "exception_only",
                            captureProbeEvents: "buffer_only"
                        )
                    ),
                    eTag: nil
                )
            ),
            random: { 0 }
        )
        await client.refreshRemoteConfig()

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let instrumentedSession = DebugBundleInstrumentedURLSession(
            session: session,
            tracePropagationTargets: [.host("api.example.com")],
            recordRequest: { request, response in
                client.captureRequest(request, response: response)
            },
            now: {
                Date(timeIntervalSince1970: 5_000)
            }
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertNotNil(request.value(forHTTPHeaderField: DebugBundleURLSessionInstrumentation.traceHeaderName))
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 503,
                httpVersion: nil,
                headerFields: ["Traceparent": "00-abc-123-01"]
            )!
            return (response, Data("oops".utf8))
        }

        let request = URLRequest(url: URL(string: "https://api.example.com/checkout")!)
        _ = try await instrumentedSession.data(for: request)
        await client.flush()

        let batches = await transport.recordedBatches()
        let event = try XCTUnwrap(batches.first?.first)
        XCTAssertEqual(event.eventType, DebugBundleEventType.requestEvent)
        XCTAssertNotNil(event.correlation?.traceId)
    }

    func testURLSessionConfigurationInstrumentationInjectsTraceHeaderAndCapturesFailureEvent() async throws {
        let server = try DebugBundleMockIngestionServer(response: .init(statusCode: 503))
        try await server.start()
        let transport = RecordingTransport()
        DebugBundle.initialize(
            DebugBundleConfig(projectToken: "token", service: "checkout-ios"),
            transport: transport
        )

        let endpointURL = await server.endpointURL(path: "/checkout")
        let endpoint = try XCTUnwrap(endpointURL)
        let configuration = URLSessionConfiguration.ephemeral.debugBundleInstrumented(
            tracePropagationTargets: [.host("127.0.0.1")]
        )
        let session = URLSession(configuration: configuration)

        let (_, response) = try await session.data(for: URLRequest(url: endpoint))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)

        await DebugBundle.flush()

        let requests = await server.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let traceID = try XCTUnwrap(request.headers[DebugBundleURLSessionInstrumentation.traceHeaderName.lowercased()])
        XCTAssertEqual(request.path, "/checkout")

        let batches = await transport.recordedBatches()
        let event = try XCTUnwrap(batches.first?.first)
        XCTAssertEqual(event.eventType, DebugBundleEventType.requestEvent)
        XCTAssertEqual(event.correlation?.traceId, traceID)

        await server.stop()
    }

    func testURLSessionConfigurationInstrumentationMatchesSpecStyleInPlaceCall() async throws {
        let server = try DebugBundleMockIngestionServer(response: .init(statusCode: 503))
        try await server.start()
        defer {
            Task {
                await server.stop()
            }
        }

        let transport = RecordingTransport()
        DebugBundle.initialize(
            DebugBundleConfig(projectToken: "token", service: "checkout-ios"),
            transport: transport
        )

        let endpointURL = await server.endpointURL(path: "/spec-style")
        let endpoint = try XCTUnwrap(endpointURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.debugBundleInstrumented(tracePropagationTargets: ["http://127.0.0.1"])

        let session = URLSession(configuration: configuration)
        _ = try await session.data(for: URLRequest(url: endpoint))
        await DebugBundle.flush()

        let requests = await server.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.path, "/spec-style")
        XCTAssertNotNil(request.headers[DebugBundleURLSessionInstrumentation.traceHeaderName.lowercased()])

        let batches = await transport.recordedBatches()
        let event = try XCTUnwrap(batches.first?.first)
        XCTAssertEqual(event.eventType, DebugBundleEventType.requestEvent)
    }

    func testAlamofireSessionInjectsTraceHeaderAndCapturesFailureEvent() async throws {
        let transport = RecordingTransport()
        let requestRecorded = expectation(description: "alamofire request recorded")
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios"),
            transport: transport,
            remoteConfigClient: StaticRemoteConfigClient(
                result: .loaded(
                    DebugBundleRemoteConfigResponse(
                        capturePolicy: DebugBundleRemoteCapturePolicy(
                            preset: "balanced",
                            captureLogs: "warning",
                            captureRequestEvents: "failures_only",
                            captureBreadcrumbs: "exception_only",
                            captureProbeEvents: "buffer_only"
                        )
                    ),
                    eTag: nil
                )
            ),
            random: { 0 }
        )
        await client.refreshRemoteConfig()

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = Session.debugBundleInstrumented(
            configuration: sessionConfiguration,
            tracePropagationTargets: ["https://api.example.com"],
            recordRequest: { request, response in
                client.captureRequest(request, response: response)
                requestRecorded.fulfill()
            },
            now: {
                Date(timeIntervalSince1970: 6_000)
            },
            traceIDProvider: { "trace-alamofire" }
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: DebugBundleURLSessionInstrumentation.traceHeaderName),
                "trace-alamofire"
            )
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 503,
                httpVersion: nil,
                headerFields: ["Traceparent": "00-abc-456-01"]
            )!
            return (response, Data("oops".utf8))
        }

        let response = await session.request("https://api.example.com/checkout").serializingData().response
        XCTAssertEqual(response.response?.statusCode, 503)

    await fulfillment(of: [requestRecorded], timeout: 1)

        await client.flush()

        let batches = await transport.recordedBatches()
        let event = try XCTUnwrap(batches.first?.first)
        XCTAssertEqual(event.eventType, DebugBundleEventType.requestEvent)
        XCTAssertEqual(event.correlation?.traceId, "trace-alamofire")
    }
}

private func readBody(from stream: InputStream?) -> Data? {
    guard let stream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let readCount = stream.read(buffer, maxLength: bufferSize)
        if readCount <= 0 {
            break
        }
        data.append(buffer, count: readCount)
    }

    return data.isEmpty ? nil : data
}

private func adaptRequest(
    _ request: URLRequest,
    using interceptor: DebugBundleAlamofireInterceptor,
    session: Session
) async throws -> URLRequest {
    try await withCheckedThrowingContinuation { continuation in
        interceptor.adapt(request, for: session) { result in
            switch result {
            case let .success(adaptedRequest):
                continuation.resume(returning: adaptedRequest)
            case let .failure(error):
                continuation.resume(throwing: error)
            }
        }
    }
}

private func waitForSendCallCount(on transport: SequencedTransport, minimum: Int) async -> Int {
    for _ in 0 ..< 100 {
        let currentCount = await transport.sendCallCount()
        if currentCount >= minimum {
            return currentCount
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await transport.sendCallCount()
}

private func waitForRecordedBatchCount(on transport: RecordingTransport, minimum: Int) async -> Int {
    for _ in 0 ..< 100 {
        let currentCount = await transport.recordedBatches().count
        if currentCount >= minimum {
            return currentCount
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await transport.recordedBatches().count
}

private struct StaticRemoteConfigClient: DebugBundleRemoteConfigClienting {
    let result: DebugBundleRemoteConfigResult

    func fetch(request: DebugBundleRemoteConfigRequest) async -> DebugBundleRemoteConfigResult {
        result
    }
}

private final class TestConnectivityMonitor: DebugBundleConnectivityMonitoring {
    var currentStatus: DebugBundleConnectivityStatus
    private var handler: (@Sendable (DebugBundleConnectivityStatus) -> Void)?

    init(status: DebugBundleConnectivityStatus) {
        self.currentStatus = status
    }

    func setUpdateHandler(_ handler: (@Sendable (DebugBundleConnectivityStatus) -> Void)?) {
        self.handler = handler
    }

    func update(_ status: DebugBundleConnectivityStatus) {
        currentStatus = status
        handler?(status)
    }
}

private actor SequencedTransport: DebugBundleTransporting {
    enum Step {
        case success(DebugBundleTransportResult)
        case failure(Error)
    }

    private var steps: [Step]
    private var calls = 0

    init(results: [Step]) {
        self.steps = results
    }

    func send(events: [DebugBundleEventEnvelope], config: DebugBundleConfig) async throws -> DebugBundleTransportResult {
        calls += 1
        guard !steps.isEmpty else {
            return DebugBundleTransportResult(statusCode: 202)
        }

        switch steps.removeFirst() {
        case let .success(result):
            return result
        case let .failure(error):
            throw error
        }
    }

    func sendCallCount() -> Int {
        calls
    }
}

private actor TestSleeper {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait(interval: TimeInterval) async {
        guard interval > 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilHasWaiter() async {
        while continuations.isEmpty {
            await Task.yield()
        }
    }

    func advanceOneTick() {
        guard !continuations.isEmpty else {
            return
        }
        continuations.removeFirst().resume()
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
