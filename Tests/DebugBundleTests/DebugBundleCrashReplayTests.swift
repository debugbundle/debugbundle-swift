import Foundation
import XCTest
import DebugBundleCrashReporter
import DebugBundleTestSupport
@testable import DebugBundle

final class DebugBundleCrashReplayTests: XCTestCase {
    func testRetainedReplayPreservesSavedTimeAndOriginWithoutApplicationHook() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DebugBundleCrashEvidenceStore(fileURL: directory.appendingPathComponent("fatal.json"))
        let saved = DebugBundleCrashReporter.persistFatalCrash(NSError(domain: "fictional", code: 1, userInfo: [NSLocalizedDescriptionKey: "saved crash"]),
            traceOrigin: .nativeFatal, store: store, occurredAt: Date().addingTimeInterval(-60), stackTrace: ["0 App 0x123 nativeCrash + 42"])
        let transport = RecordingTransport()
        let config = DebugBundleConfig(projectToken: "fictional", service: "ios", offlineQueueURL: directory.appendingPathComponent("queue.json"),
            beforeSend: { _ in XCTFail("Retained native reports skip application hooks"); return nil })
            .withEvidenceOptions(.init(evidenceCapabilities: .init(features: ["exception_evidence_v1"])))
        let client = makeIsolatedClient(config: config, transport: transport, random: { 0 })
        XCTAssertTrue(DebugBundleCrashReporter.replayPendingCrash(store: store, client: client))
        await client.flush()
        XCTAssertNil(store.load())
        let events = await transport.recordedBatches().flatMap { $0 }
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.eventId, saved.eventId)
        XCTAssertEqual(event.occurredAt, saved.occurredAt)
        XCTAssertEqual(event.payload["message"], .string("saved crash"))
        XCTAssertEqual(event.payload["exception_evidence"]?.objectValue?["nodes"]?.arrayValue?.first?.objectValue?["trace_origin"], .string("native_fatal"))
    }

    func testUnacknowledgedCustomStoreKeepsCrashAndRepeatedReportsStayPrimary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DebugBundleCrashEvidenceStore(fileURL: directory.appendingPathComponent("fatal.json"))
        let saved = DebugBundleCrashReporter.persistFatalCrash(NSError(domain: "fictional", code: 1), store: store)
        let transport = RecordingTransport()
        let client = makeIsolatedClient(config: .init(projectToken: "fictional", service: "ios", flushInterval: 60),
            transport: transport, queueStore: ReplayLegacyQueue(), random: { 0 })
        for _ in 0..<4 {
            XCTAssertTrue(DebugBundleCrashReporter.replayPendingCrash(store: store, client: client))
            await client.flush()
            XCTAssertNotNil(store.load())
        }
        let events = await transport.recordedBatches().flatMap { $0 }
        XCTAssertEqual(events.count, 4)
        XCTAssertTrue(events.allSatisfy { $0.eventType == "frontend_exception" && $0.eventId == saved.eventId && $0.occurredAt == saved.occurredAt })
    }

    func testLegacyRecordGetsOneStableIdentityAndUnknownOrigin() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fatal.json")
        let old: [String: Any] = ["version": 1, "mechanism": "manual", "errorType": "LegacyError", "message": "legacy crash",
            "occurredAt": debugBundleTimestamp(Date().addingTimeInterval(-60)), "threadName": "main", "stackTrace": ["unparsed supplied trace"]]
        try JSONSerialization.data(withJSONObject: old).write(to: file)
        let store = DebugBundleCrashEvidenceStore(fileURL: file), transport = RecordingTransport()
        XCTAssertEqual(store.load()?.traceOrigin, "unknown")
        XCTAssertNil(store.load()?.eventId)
        let client = makeIsolatedClient(config: DebugBundleConfig(projectToken: "fictional", service: "ios", flushInterval: 60)
            .withEvidenceOptions(.init(evidenceCapabilities: .init(features: ["exception_evidence_v1"]))),
            transport: transport, queueStore: ReplayLegacyQueue(), random: { 0 })
        XCTAssertTrue(DebugBundleCrashReporter.replayPendingCrash(store: store, client: client))
        let identity = try XCTUnwrap(store.load()?.eventId)
        XCTAssertFalse(DebugBundleCrashReporter.replayPendingCrash(store: store, client: client))
        await client.flush()
        XCTAssertEqual(store.load()?.eventId, identity)
        let events = await transport.recordedBatches().flatMap { $0 }
        XCTAssertEqual(events.first?.eventId, identity)
        XCTAssertEqual(events.first?.payload["exception_evidence"]?.objectValue?["nodes"]?.arrayValue?.first?.objectValue?["trace_origin"], .string("unknown"))
    }

    func testOlderHandoffCannotClearNewerSavedCrash() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DebugBundleCrashEvidenceStore(fileURL: directory.appendingPathComponent("fatal.json"))
        _ = DebugBundleCrashReporter.persistFatalCrash(NSError(domain: "old", code: 1), store: store)
        let held = ReplayHeldQueue()
        let client = makeIsolatedClient(config: .init(projectToken: "fictional", service: "ios", flushInterval: 60),
            transport: RecordingTransport(), queueStore: held, random: { 0 })
        XCTAssertTrue(DebugBundleCrashReporter.replayPendingCrash(store: store, client: client))
        await fulfillment(of: [held.entered], timeout: 2)
        let newer = DebugBundleCrashReporter.persistFatalCrash(NSError(domain: "new", code: 2, userInfo: [NSLocalizedDescriptionKey: "new crash"]), store: store)
        held.release.signal()
        await client.flush()
        XCTAssertEqual(store.load()?.eventId, newer.eventId)
        XCTAssertEqual(store.load()?.message, "new crash")
    }
}

private struct ReplayLegacyQueue: DebugBundleQueueStoring {
    func load(now: Date, ttl: TimeInterval) -> [DebugBundleEventEnvelope] { [] }
    func persist(_ events: [DebugBundleEventEnvelope]) {}
}
private final class ReplayHeldQueue: DebugBundleAcknowledgingQueueStore {
    let entered = XCTestExpectation(description: "retained handoff entered")
    let release = DispatchSemaphore(value: 0)
    private var held = false
    func load(now: Date, ttl: TimeInterval) -> [DebugBundleEventEnvelope] { [] }
    func persist(_ events: [DebugBundleEventEnvelope]) {}
    func persistAcknowledging(_ events: [DebugBundleEventEnvelope]) -> Bool {
        if !events.isEmpty && !held { held = true; entered.fulfill(); release.wait() }
        return true
    }
}
