import Foundation
import XCTest
import DebugBundleTestSupport
@_spi(DebugBundleRuntime) @testable import DebugBundle

final class DebugBundleRuntimeReportTests: XCTestCase {
    func testRuntimeReportPreservesOccurrenceAndSkipsHookWithSmallHonestEvidence() async throws {
        let transport = RecordingTransport(), counter = RuntimeReportCounter(), store = RuntimeReportStore()
        let capturedAt = Date().addingTimeInterval(-60)
        let report = DebugBundleRuntimeReport(eventId: UUID().uuidString.lowercased(), name: "NativeCrash", message: "fatal token=fictional-secret",
            occurredAt: debugBundleTimestamp(capturedAt), stackTrace: (0..<32).map { "\($0) App 0x123 applicationFunction\($0) + 42" }, traceOrigin: "native_fatal")
        let client = makeIsolatedClient(config: DebugBundleConfig(projectToken: "fictional", service: "ios", beforeSend: { event in counter.hook(); return event })
            .withEvidenceOptions(.init(evidenceCapabilities: .init(features: ["exception_evidence_v1"]))), transport: transport, queueStore: store, random: { 0 })
        XCTAssertTrue(client.captureRuntimeReport(report, context: ["fatal_crash": true], onRetained: counter.retained))
        await client.flush()
        let events = await transport.recordedBatches().flatMap { $0 }
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.eventId, report.eventId)
        XCTAssertEqual(event.occurredAt, report.occurredAt)
        XCTAssertEqual(event.payload["name"], .string(String(reflecting: NSError.self)))
        XCTAssertEqual(event.payload["message"], .string("fatal token=[REDACTED]"))
        XCTAssertEqual(counter.hooks, 0)
        XCTAssertEqual(counter.retainedCount, 1)
        let graph = try XCTUnwrap(event.payload["exception_evidence"])
        XCTAssertLessThanOrEqual(DebugBundleAcceptingJSONSize.bytes(.object(["exception_evidence": graph])), 4096)
        let nodes = try XCTUnwrap(graph.objectValue?["nodes"]?.arrayValue)
        XCTAssertLessThanOrEqual(nodes.count, 2)
        XCTAssertLessThanOrEqual(nodes.reduce(0) { $0 + ($1.objectValue?["frames"]?.arrayValue?.count ?? 0) }, 8)
        XCTAssertEqual(nodes.first?.objectValue?["trace_origin"], .string("native_fatal"))
        XCTAssertTrue(isValidBeforeSendEvent(event))
    }

    func testPreviousCrashAcknowledgementDoesNotClearCurrentLaunchEvidence() async throws {
        let transport = RuntimePartialTransport(), clock = RuntimeReportClock()
        let client = makeIsolatedClient(config: .init(projectToken: "fictional", service: "ios", batchSize: 10, flushInterval: 60),
            transport: transport, clock: clock.now, random: { 0 })
        client.recordBreadcrumb(breadcrumbType: "current_launch", data: ["route": "/current"])
        client.probe("current.checkpoint", data: ["value": 1])
        let report = DebugBundleRuntimeReport(eventId: UUID().uuidString.lowercased(), name: "NativeCrash", message: "previous crash",
            occurredAt: debugBundleTimestamp(clock.now().addingTimeInterval(-60)), stackTrace: [])
        XCTAssertTrue(client.captureRuntimeReport(report))
        client.captureException(NSError(domain: "current", code: 1, userInfo: [NSLocalizedDescriptionKey: "current failure one"]))
        await client.flush()
        client.captureException(NSError(domain: "current", code: 2, userInfo: [NSLocalizedDescriptionKey: "current failure two"]))
        clock.advance(10)
        await client.flush()
        let events = await transport.recordedBatches().flatMap { $0 }
        let later = try XCTUnwrap(events.first { $0.payload["message"] == .string("current failure two") })
        XCTAssertFalse(later.payload["breadcrumbs"]?.arrayValue?.isEmpty ?? true)
        XCTAssertFalse(later.payload["probe_data"]?.objectValue?["items"]?.arrayValue?.isEmpty ?? true)
    }

    func testCanonicalAcceptanceCallbackRunsOutsideClientAndQueueLocks() async {
        let counter = RuntimeReportCounter()
        let client = makeIsolatedClient(config: .init(projectToken: "fictional", service: "ios", flushInterval: 60),
            transport: RuntimeCanonicalTransport(), queueStore: RuntimeLegacyStore(), random: { 0 })
        let report = DebugBundleRuntimeReport(eventId: UUID().uuidString.lowercased(), name: "NativeCrash", message: "fictional",
            occurredAt: debugBundleTimestamp(Date()), stackTrace: [])
        XCTAssertTrue(client.captureRuntimeReport(report, onRetained: { [weak client] in
            client?.captureLog("retention callback", level: .error)
            counter.retained()
        }))
        await client.flush()
        XCTAssertEqual(counter.retainedCount, 1)
    }

    func testLegacyStoreCannotClaimDurableRetentionAndDuplicateAdmissionStaysBounded() async {
        let counter = RuntimeReportCounter(), transport = RecordingTransport()
        let client = makeIsolatedClient(config: .init(projectToken: "fictional", service: "ios"), transport: transport, queueStore: RuntimeLegacyStore(), random: { 0 })
        let report = DebugBundleRuntimeReport(eventId: UUID().uuidString.lowercased(), name: "NativeCrash", message: "fictional",
            occurredAt: debugBundleTimestamp(Date()), stackTrace: [], traceOrigin: "unknown")
        XCTAssertTrue(client.captureRuntimeReport(report, onRetained: counter.retained))
        XCTAssertFalse(client.captureRuntimeReport(report, onRetained: counter.retained))
        await client.flush()
        XCTAssertEqual(counter.retainedCount, 0)
    }
}

private final class RuntimeReportCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var hookValue = 0, retainedValue = 0
    var hooks: Int { lock.withLock { hookValue } }
    var retainedCount: Int { lock.withLock { retainedValue } }
    func hook() { lock.withLock { hookValue += 1 } }
    func retained() { lock.withLock { retainedValue += 1 } }
}
private final class RuntimeReportStore: DebugBundleAcknowledgingQueueStore {
    func load(now: Date, ttl: TimeInterval) -> [DebugBundleEventEnvelope] { [] }
    func persist(_ events: [DebugBundleEventEnvelope]) {}
    func persistAcknowledging(_ events: [DebugBundleEventEnvelope]) -> Bool { true }
}
private final class RuntimeLegacyStore: DebugBundleQueueStoring {
    func load(now: Date, ttl: TimeInterval) -> [DebugBundleEventEnvelope] { [] }
    func persist(_ events: [DebugBundleEventEnvelope]) {}
}

private struct RuntimeCanonicalTransport: DebugBundleTransporting {
    func send(events: [DebugBundleEventEnvelope], config: DebugBundleConfig) async throws -> DebugBundleTransportResult {
        .init(statusCode: 202, acknowledgement: .init(accepted: events.count, rejected: 0), acknowledgementRequired: true)
    }
}

private actor RuntimePartialTransport: DebugBundleTransporting {
    private var batches: [[DebugBundleEventEnvelope]] = []
    func recordedBatches() -> [[DebugBundleEventEnvelope]] { batches }
    func send(events: [DebugBundleEventEnvelope], config: DebugBundleConfig) async throws -> DebugBundleTransportResult {
        batches.append(events)
        if batches.count == 1 {
            XCTAssertEqual(events.count, 2)
            return .init(statusCode: 202, acknowledgement: .init(accepted: 1, rejected: 1, errors: [.init(index: 1, reason: "rate_limited")]), acknowledgementRequired: true)
        }
        return .init(statusCode: 202, acknowledgement: .init(accepted: events.count, rejected: 0), acknowledgementRequired: true)
    }
}
private final class RuntimeReportClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}
