import Foundation
import XCTest
import DebugBundleTestSupport
@testable import DebugBundle

final class DebugBundleNativeExceptionEvidenceTests: XCTestCase {
    func testLoggedNativeErrorUsesOnePrimaryExceptionAndKeepsUnderlyingCause() async throws {
        let root = NSError(domain: "outer", code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: "cause", code: 2)])
        let transport = RecordingTransport()
        let client = makeIsolatedClient(config: DebugBundleConfig(projectToken: "fictional", service: "ios", flushInterval: 60)
            .withEvidenceOptions(.init(evidenceCapabilities: .init(features: ["exception_evidence_v1"]))), transport: transport, random: { 0 })
        client.captureLog("operation failed", level: .error, context: ["error": root])
        await client.flush()
        withExtendedLifetime(root) {}
        let events = await transport.recordedBatches().flatMap { $0 }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.eventType, DebugBundleEventType.frontendException)
        XCTAssertEqual(events.first?.payload["exception_evidence"]?.objectValue?["nodes"]?.arrayValue?.count, 2)
        client.capturePolicy = .fromRemotePolicy(.init(preset: "balanced"))
        client.captureLog("warning context", level: .warning, context: ["error": root])
        await client.flush()
        let afterWarning = await transport.recordedBatches().flatMap { $0 }
        XCTAssertEqual(afterWarning.last?.eventType, DebugBundleEventType.logEvent)
    }
    func testNativeUnderlyingAndAggregateErrorsPreservePrimaryAndHonestOrigins() async throws {
        let shared = NSError(domain: "cause", code: 2, userInfo: [NSLocalizedDescriptionKey: "cause token=fictional-secret"])
        let root = NSError(domain: "outer", code: 1, userInfo: [NSLocalizedDescriptionKey: "primary failure",
            NSUnderlyingErrorKey: shared, NSMultipleUnderlyingErrorsKey: [shared, NSError(domain: "related", code: 3)]])
        let transport = RecordingTransport()
        let client = makeIsolatedClient(config: DebugBundleConfig(projectToken: "fictional", service: "ios", flushInterval: 60)
            .withEvidenceOptions(.init(evidenceCapabilities: .init(features: ["exception_evidence_v1"]))), transport: transport, random: { 0 })
        client.captureException(root)
        await client.flush()
        withExtendedLifetime(root) {}
        let events = await transport.recordedBatches().flatMap { $0 }
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.payload["message"], .string("primary failure"))
        let graph = try XCTUnwrap(event.payload["exception_evidence"]?.objectValue)
        let nodes = try XCTUnwrap(graph["nodes"]?.arrayValue)
        XCTAssertEqual(nodes.count, 3)
        XCTAssertEqual(nodes[0].objectValue?["trace_origin"], .string("capture"))
        XCTAssertFalse(nodes[0].objectValue?["frames"]?.arrayValue?.isEmpty ?? true)
        XCTAssertEqual(nodes[1].objectValue?["trace_origin"], .string("unavailable"))
        XCTAssertEqual(nodes[1].objectValue?["message"], .string("cause token=[REDACTED]"))
        XCTAssertEqual(nodes[0].objectValue?["relationships"]?.arrayValue?.count, 3)
        XCTAssertTrue(isValidBeforeSendEvent(event))
    }
    func testBoundsSharedDepthCyclesUnicodeAndSafeUnknownChildren() throws {
        let redactor = DebugBundleRedactor(sensitiveKeys: DebugBundleConfig.defaultRedactFields)
        var deep = NSError(domain: "leaf", code: 0)
        for index in 0..<12 { deep = NSError(domain: "depth-\(index)", code: index, userInfo: [NSUnderlyingErrorKey: deep]) }
        let children = (0..<12).map { NSError(domain: "child-\($0)", code: $0) }
        let outer = NSError(domain: "outer", code: 0, userInfo: [NSUnderlyingErrorKey: deep, NSMultipleUnderlyingErrorsKey: children])
        let lines = (0..<100).map { "\($0) App 0x00000123 applicationFunction\($0) + 42" }.joined(separator: "\n")
        let graph = try XCTUnwrap(DebugBundleExceptionEvidence.capture(error: outer,
            name: String(repeating: "🙂", count: 400), message: String(repeating: "🙂", count: 2000), stack: lines, redactor: redactor))
        XCTAssertTrue(graph.objectValue?["truncated"] == .bool(true))
        XCTAssertLessThanOrEqual(graph.objectValue?["nodes"]?.arrayValue?.count ?? 99, 8)
        XCTAssertLessThanOrEqual(DebugBundleAcceptingJSONSize.bytes(graph), 31_000)
        try assertValid(graph)

        let array = NSMutableArray()
        let cyclic = NSError(domain: "cycle", code: 0, userInfo: [NSMultipleUnderlyingErrorsKey: array])
        array.add(cyclic)
        defer { array.removeAllObjects() }
        let cycle = try XCTUnwrap(DebugBundleExceptionEvidence.capture(error: cyclic, name: "cycle", message: "cycle", stack: "", redactor: redactor))
        XCTAssertEqual(cycle.objectValue?["nodes"]?.arrayValue?.count, 1)
        XCTAssertEqual(cycle.objectValue?["truncated"], .bool(true))
        try assertValid(cycle)

        let custom = EvidenceCustomError()
        let unsafe = try XCTUnwrap(DebugBundleExceptionEvidence.capture(error: custom, name: "custom", message: "fallback", stack: "", redactor: redactor))
        XCTAssertEqual(custom.calls, 0)
        XCTAssertEqual(unsafe.objectValue?["unavailable_reason"], .string("unsafe"))
        try assertValid(unsafe)
        let unsupported = try XCTUnwrap(DebugBundleExceptionEvidence.capture(error: nil, name: "value", message: "fallback", stack: "unparsed original stack", redactor: redactor))
        XCTAssertEqual(unsupported.objectValue?["unavailable_reason"], .string("unsupported"))
        XCTAssertEqual(unsupported.objectValue?["nodes"]?.arrayValue?.first?.objectValue?["parsing_status"], .string("unparsed"))
        try assertValid(unsupported)
    }

    func testOversizedUserInfoAndUnsupportedAggregateNeverTraverseForeignValues() throws {
        let redactor = DebugBundleRedactor(sensitiveKeys: [])
        let custom = EvidenceCustomError()
        let unknown = NSError(domain: "outer", code: 0, userInfo: [NSMultipleUnderlyingErrorsKey: custom, NSUnderlyingErrorKey: custom])
        let graph = try XCTUnwrap(DebugBundleExceptionEvidence.capture(error: unknown, name: "outer", message: "primary", stack: "", redactor: redactor))
        XCTAssertEqual(custom.calls, 0)
        XCTAssertEqual(graph.objectValue?["unavailable_reason"], .string("unsafe"))
        XCTAssertEqual(graph.objectValue?["nodes"]?.arrayValue?.count, 2)
        try assertValid(graph)
        var info: [String: Any] = [:]
        for index in 0..<51 { info["key-\(index)"] = index }
        info[NSUnderlyingErrorKey] = custom
        let large = NSError(domain: "large", code: 0, userInfo: info)
        let bounded = try XCTUnwrap(DebugBundleExceptionEvidence.capture(error: large, name: "large", message: "primary", stack: "", redactor: redactor))
        XCTAssertEqual(bounded.objectValue?["truncated"], .bool(true))
        XCTAssertEqual(bounded.objectValue?["nodes"]?.arrayValue?.count, 1)
        XCTAssertEqual(custom.calls, 0)
        try assertValid(bounded)
    }

    func testDeferredNativeAttachmentDoesNotRetainErrorOrItsUnderlyingGraph() throws {
        var error: NSError? = NSError(domain: "temporary", code: 0, userInfo: [NSUnderlyingErrorKey: NSError(domain: "cause", code: 1)])
        weak var observed = error
        let deferred = DebugBundleDeferredError(error!)
        error = nil
        XCTAssertNil(observed)
        let graph = try XCTUnwrap(deferred.workerEvidence(name: "temporary", message: "primary", stack: "", redactor: .init(sensitiveKeys: [])))
        XCTAssertEqual(graph.objectValue?["unavailable_reason"], .string("unknown"))
        XCTAssertNil(deferred.workerMessage())
        try assertValid(graph)
    }

    private func assertValid(_ graph: JSONValue, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "evidence-wire-cases", withExtension: "json"))
        let corpus = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let raw = try XCTUnwrap(corpus.objectValue?["events"]?.arrayValue?.first?.objectValue?["event"])
        var event = try JSONDecoder().decode(DebugBundleEventEnvelope.self, from: JSONEncoder().encode(raw))
        event.payload["exception_evidence"] = graph
        XCTAssertTrue(isValidBeforeSendEvent(event), file: file, line: line)
    }

}


private final class EvidenceCustomError: LocalizedError, CustomNSError {
    var calls = 0
    var errorDescription: String? { calls += 1; return "unsafe" }
    var errorUserInfo: [String: Any] { calls += 1; return [:] }
}
