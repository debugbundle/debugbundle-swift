import Foundation
import XCTest
@testable import DebugBundle

final class DebugBundleEvidenceHTTPTests: XCTestCase {
    override func tearDown() { EvidenceURLProtocol.handler = nil; super.tearDown() }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EvidenceURLProtocol.self]
        return URLSession(configuration: config)
    }
    private let ack = Data("{\"accepted\":0,\"rejected\":0,\"errors\":[]}".utf8)

    func testDeadlineDoesNotWaitForDelayedNativeCancellation() async throws {
        let response = URLResponse(url: URL(string: "https://example.invalid")!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        let completed = expectation(description: "late native callback completes")
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await DebugBundleHTTPReply.withDeadline(timeout: 0.03) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                        continuation.resume(returning: .init(data: Data(), response: response))
                        completed.fulfill()
                    }
                }
            }
            XCTFail("The deadline must reject a native callback that ignores cancellation")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.2)
        await fulfillment(of: [completed], timeout: 2)
    }

    func testCallerCancellationDoesNotWaitForDelayedNativeCallback() async throws {
        let reply = DebugBundleHTTPReply.Reply(data: Data(), response: URLResponse(url: URL(string: "https://example.invalid")!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        let entered = expectation(description: "native read entered")
        let completed = expectation(description: "late cancelled read completed")
        let request = Task {
            try await DebugBundleHTTPReply.withDeadline(timeout: 10) {
                await withCheckedContinuation { continuation in
                    entered.fulfill()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                        continuation.resume(returning: reply)
                        completed.fulfill()
                    }
                }
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let started = ProcessInfo.processInfo.systemUptime
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("Caller cancellation must reject the native read")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.2)
        await fulfillment(of: [completed], timeout: 2)
    }

    func testAcknowledgedChunkSnapshotRemainsChargedUntilTheSenderReleasesItsTail() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let calls = EvidenceCallCounter(), handle = EvidenceHTTPClientHandle()
        EvidenceURLProtocol.handler = { request in
            let body = request.httpBody ?? EvidenceURLProtocol.body(request.httpBodyStream)
            let value = try JSONDecoder().decode(JSONValue.self, from: body)
            let count = try XCTUnwrap(value.objectValue?["events"]?.arrayValue?.count)
            let index = calls.nextSend()
            if index == 2 {
                handle.client?.captureException(NSError(domain: "fictional", code: 3, userInfo: [NSLocalizedDescriptionKey: "third failure"] ))
            }
            let reply: JSONValue = .object(["accepted": .number(Double(count)), "rejected": .number(0), "errors": .array([])])
            return (200, [:], try JSONEncoder().encode(reply), index == 2 ? 0.15 : 0)
        }
        // This large-payload case asserts snapshot ownership, not a request latency
        // budget. Leave encoding headroom on older simulators; deadline cases below
        // retain their explicit short limits.
        let client = makeIsolatedClient(config: .init(projectToken: "fictional", service: "ios", batchSize: 10, flushInterval: 60, requestTimeout: 30,
            offlineQueueMaxEvents: 2, beforeSend: { input in
                guard input.eventType == "frontend_exception" else { return input }
                calls.hook()
                var event = input
                event.context = Dictionary(uniqueKeysWithValues: (0..<10).map { ("field-\($0)", JSONValue.string(String(repeating: "/", count: 10_000))) })
                return event
            }), transport: DebugBundleHTTPTransport(session: session), random: { 0 })
        handle.client = client
        client.captureException(NSError(domain: "fictional", code: 1, userInfo: [NSLocalizedDescriptionKey: "first failure"]))
        client.captureException(NSError(domain: "fictional", code: 2, userInfo: [NSLocalizedDescriptionKey: "second failure"]))
        await client.flush()
        await client.waitForPendingCapture()
        XCTAssertEqual(calls.sendCount, 2)
        XCTAssertEqual(calls.hookCount, 2, "The still-owned initial sender snapshot must remain inside the configured count budget")
    }

    func testExplicitInvalidEventAfterProofLossRetriesLatestCompatiblePrimaryOnce() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let calls = EvidenceCallCounter(), clock = EvidenceHTTPClock()
        let identity = UUID().uuidString.lowercased()
        EvidenceURLProtocol.handler = { request in
            let body = request.httpBody ?? EvidenceURLProtocol.body(request.httpBodyStream)
            let value = try JSONDecoder().decode(JSONValue.self, from: body)
            let event = try XCTUnwrap(value.objectValue?["events"]?.arrayValue?.first?.objectValue)
            XCTAssertEqual(event["event_id"], .string(identity))
            XCTAssertEqual(event["payload"]?.objectValue?["message"], .string("latest accepted hook failure"))
            let index = calls.nextSend()
            if index == 1 { XCTAssertNotNil(event["payload"]?.objectValue?["exception_evidence"]) }
            else { XCTAssertNil(event["payload"]?.objectValue?["exception_evidence"]) }
            return (200, [:], Data("{\"accepted\":0,\"rejected\":1,\"errors\":[{\"index\":0,\"reason\":\"invalid_event\"}]}".utf8), 0)
        }
        let client = makeIsolatedClient(config: DebugBundleConfig(projectToken: "fictional", service: "ios", batchSize: 10, flushInterval: 60,
            beforeSend: { input in
                calls.hook()
                var event = input
                event.eventId = identity
                event.payload["message"] = .string("latest accepted hook failure")
                return event
            }).withEvidenceOptions(.init(evidenceCapabilities: .init(features: ["exception_evidence_v1"]))),
            transport: DebugBundleHTTPTransport(session: session), clock: clock.now, random: { 0 })
        let error = NSError(domain: "fictional", code: 1)
        client.captureException(error)
        await client.flush()
        clock.advance(10)
        await client.flush()
        clock.advance(10)
        await client.flush()
        withExtendedLifetime(error) {}
        XCTAssertEqual(calls.sendCount, 2, "Only one compatible primary retry is permitted")
        XCTAssertEqual(calls.hookCount, 1)
    }

    func testNativeChunkFailureRetainsBothOriginalsAndChunksShareOneDeadline() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let calls = EvidenceCallCounter(), clock = EvidenceHTTPClock()
        let timeouts = EvidenceHTTPTimeouts()
        EvidenceURLProtocol.handler = { request in
            let body = request.httpBody ?? EvidenceURLProtocol.body(request.httpBodyStream)
            XCTAssertLessThanOrEqual(body.count, 262_144)
            let value = try JSONDecoder().decode(JSONValue.self, from: body)
            let events = try XCTUnwrap(value.objectValue?["events"]?.arrayValue)
            XCTAssertEqual(events.count, 1)
            let index = calls.nextSend()
            if index == 1 { return (503, [:], Data(), 0) }
            timeouts.append(request.timeoutInterval)
            let expected = index == 2 ? "first failure" : "second failure"
            XCTAssertEqual(events.first?.objectValue?["payload"]?.objectValue?["message"], .string(expected))
            return (200, [:], Data("{\"accepted\":1,\"rejected\":0,\"errors\":[]}".utf8), index == 2 ? 0.05 : 0)
        }
        let client = makeIsolatedClient(config: .init(projectToken: "fictional", service: "ios", batchSize: 10, flushInterval: 60,
            requestTimeout: 1, beforeSend: { input in
                calls.hook()
                var event = input
                event.context = Dictionary(uniqueKeysWithValues: (0..<10).map { ("field-\($0)", JSONValue.string(String(repeating: "/", count: 10_000))) })
                return event
            }), transport: DebugBundleHTTPTransport(session: session), clock: clock.now, random: { 0 })
        client.captureException(NSError(domain: "fictional", code: 1, userInfo: [NSLocalizedDescriptionKey: "first failure"]))
        client.captureException(NSError(domain: "fictional", code: 2, userInfo: [NSLocalizedDescriptionKey: "second failure"]))
        await client.flush()
        XCTAssertEqual(calls.sendCount, 1)
        clock.advance(10)
        await client.flush()
        XCTAssertEqual(calls.sendCount, 3)
        XCTAssertEqual(calls.hookCount, 2)
        let durations = timeouts.values
        XCTAssertEqual(durations.count, 2)
        if durations.count == 2 { XCTAssertLessThan(durations[1], durations[0] - 0.03) }
    }

    func testNativeFlushSplitsActualSerializedBytesWithoutRepeatingHooks() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let calls = EvidenceCallCounter()
        EvidenceURLProtocol.handler = { request in
            let body = request.httpBody ?? EvidenceURLProtocol.body(request.httpBodyStream)
            XCTAssertLessThanOrEqual(body.count, 262_144)
            let value = try JSONDecoder().decode(JSONValue.self, from: body)
            let events = try XCTUnwrap(value.objectValue?["events"]?.arrayValue)
            XCTAssertEqual(events.count, 1)
            _ = calls.nextSend()
            let reply: JSONValue = .object(["accepted": .number(Double(events.count)), "rejected": .number(0), "errors": .array([])])
            return (200, [:], try JSONEncoder().encode(reply), 0)
        }
        let client = makeIsolatedClient(config: .init(projectToken: "fictional", service: "ios", batchSize: 10, flushInterval: 60,
            beforeSend: { input in
                calls.hook()
                var event = input
                event.context = Dictionary(uniqueKeysWithValues: (0..<10).map { ("field-\($0)", JSONValue.string(String(repeating: "/", count: 10_000))) })
                return event
            }), transport: DebugBundleHTTPTransport(session: session), random: { 0 })
        let first = NSError(domain: "fictional", code: 1, userInfo: [NSLocalizedDescriptionKey: "first failure"])
        let second = NSError(domain: "fictional", code: 2, userInfo: [NSLocalizedDescriptionKey: "second failure"])
        client.captureException(first); client.captureException(second)
        await client.flush()
        withExtendedLifetime((first, second)) {}
        XCTAssertEqual(calls.sendCount, 2)
        XCTAssertEqual(calls.hookCount, 2)
    }

    func testNativeProofLossDowngradesAlreadyPreparedRetryWithoutCallingHookAgain() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "evidence-wire-cases", withExtension: "json"))
        let corpus = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixture))
        let graph = try XCTUnwrap(corpus.objectValue?["events"]?.arrayValue?.first?.objectValue?["event"]?.objectValue?["payload"]?.objectValue?["exception_evidence"])
        let calls = EvidenceCallCounter()
        var now = Date()
        EvidenceURLProtocol.handler = { request in
            let body = request.httpBody ?? EvidenceURLProtocol.body(request.httpBodyStream)
            let root = try JSONDecoder().decode(JSONValue.self, from: body)
            let graph = root.objectValue?["events"]?.arrayValue?.first?.objectValue?["payload"]?.objectValue?["exception_evidence"]
            let index = calls.nextSend()
            if index == 1 { XCTAssertNotNil(graph); return (503, [:], Data(), 0) }
            XCTAssertNil(graph, "Proof loss must be reapplied to a previously prepared retry")
            return (200, [:], Data("{\"accepted\":1,\"rejected\":0,\"errors\":[]}".utf8), 0)
        }
        let config = DebugBundleConfig(projectToken: "fictional", service: "ios", flushInterval: 60, beforeSend: { input in
            calls.hook()
            var event = input
            event.payload["exception_evidence"] = graph
            return event
        }).withEvidenceOptions(.init(evidenceCapabilities: .init(features: ["exception_evidence_v1"])))
        let client = makeIsolatedClient(config: config, transport: DebugBundleHTTPTransport(session: session), clock: { now }, random: { 0 })
        client.captureException(NSError(domain: "fictional", code: 1))
        await client.flush()
        now = now.addingTimeInterval(10)
        await client.flush()
        XCTAssertEqual(calls.sendCount, 2)
        XCTAssertEqual(calls.hookCount, 1)
    }

    func testNativeRepliesRejectOversizeAndEncodedDataBeforeAcknowledgement() async throws {
        for (headers, body) in [([String: String](), ack + Data(repeating: 32, count: 262_144)),
            (["Content-Length": "262145"], ack), (["Content-Encoding": "gzip"], ack),
            ([:], ack + Data([255]))] {
            let session = session()
            defer { session.invalidateAndCancel() }
            EvidenceURLProtocol.handler = { _ in (200, headers, body, 0) }
            do {
                _ = try await DebugBundleHTTPTransport(session: session).send(events: [], config: .init(projectToken: "fictional"))
                XCTFail("An invalid bounded native response must not create a successful result")
            } catch { }
        }
    }

    func testNativeReplyDeadlineIncludesWaitingForResponse() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        EvidenceURLProtocol.handler = { _ in (200, [:], self.ack, 0.3) }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await DebugBundleHTTPTransport(session: session).send(events: [], config: .init(projectToken: "fictional", requestTimeout: 0.1))
            XCTFail("Native reply must share the request deadline")
        } catch { }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.25)
    }

    func testNativeTransportAndConfigOptIntoExistingDiscoveryAndKeepRawDescriptor() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let descriptor = DebugBundleEvidenceCapabilities(features: DebugBundleEvidenceCapabilities.known)
        EvidenceURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-DebugBundle-Evidence"), "1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
            let value: JSONValue = request.httpMethod == "GET"
                ? .object(["probes_enabled": .bool(true), "remote_probes_enabled": .bool(false), "active_probes": .array([]),
                    "poll_interval_ms": .number(0), "evidence_capabilities": descriptor.wire])
                : .object(["accepted": .number(0), "rejected": .number(0), "errors": .array([]), "evidence_capabilities": descriptor.wire])
            return (200, ["Content-Encoding": "identity"], try JSONEncoder().encode(value), 0)
        }
        let result = try await DebugBundleHTTPTransport(session: session).send(events: [], config: .init(projectToken: "fictional"))
        XCTAssertEqual(result.evidenceCapabilities, descriptor.wire)
        let fetched = await DebugBundleHTTPRemoteConfigClient(session: session).fetch(request: .init(projectToken: "fictional", endpoint: DebugBundleConfig.defaultEndpoint, timeout: 1))
        guard case let .loaded(config, _) = fetched else { return XCTFail("Expected native config response") }
        XCTAssertEqual(config.evidenceCapabilities, descriptor.wire)
    }
}

private final class EvidenceURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data, TimeInterval))?
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, headers, data, delay) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
            work = item
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { work?.cancel(); work = nil }
    static func body(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class EvidenceCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var sends = 0, hooks = 0
    func nextSend() -> Int { lock.withLock { sends += 1; return sends } }
    func hook() { lock.withLock { hooks += 1 } }
    var sendCount: Int { lock.withLock { sends } }
    var hookCount: Int { lock.withLock { hooks } }
}

private final class EvidenceHTTPClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}
private final class EvidenceHTTPTimeouts: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimeInterval] = []
    var values: [TimeInterval] { lock.withLock { stored } }
    func append(_ value: TimeInterval) { lock.withLock { stored.append(value) } }
}

private final class EvidenceHTTPClientHandle: @unchecked Sendable { weak var client: DebugBundleClient? }
