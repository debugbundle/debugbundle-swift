import Darwin
import Foundation
import XCTest
import DebugBundleTestSupport
@testable import DebugBundle

final class DebugBundleEvidencePerformanceTests: XCTestCase {
    func testEvidenceComparisonPreservesNativeFailuresUnderQueuePressure() async throws {
        let pairs = 20
        let selected = ProcessInfo.processInfo.environment["EVIDENCE_PERFORMANCE_CASE"]
        if let selected { XCTAssertTrue(["off-empty", "off-full", "on-empty", "on-full"].contains(selected)) }
        for repetition in 0..<4 {
            for enabled in [false, true] {
                for pressure in [false, true] {
                    let name = (enabled ? "on" : "off") + (pressure ? "-full" : "-empty")
                    if let selected, selected != name { continue }
                    let store = PerformanceQueueStore()
                    let transport = RecordingTransport()
                    let config = DebugBundleConfig(projectToken: "synthetic", environment: "local", batchSize: 1001,
                        flushInterval: 3600, requestTimeout: 30, maxEventsPerSession: 2000,
                        offlineQueueMaxEvents: 256, offlineQueueMaxBytes: 2 * 1024 * 1024)
                        .withEvidenceOptions(.init(captureExceptionEvidence: enabled, captureRecoveryObservations: enabled,
                            evidenceCapabilities: .init(features: ["exception_evidence_v1", "recovery_v1"])))
                    let client = makeIsolatedClient(config: config, transport: transport, queueStore: store,
                        remoteConfigClient: PerformancePolicy(), random: { 0 })
                    defer { store.release.signal() }
                    await fulfillment(of: [store.entered], timeout: 5)
                    await client.refreshRemoteConfig()
                    if pressure {
                        autoreleasepool {
                            for index in 0..<256 { client.captureLog("retained warning \(index)", level: .warning) }
                        }
                    }
                    let errors = (0..<pairs).map { index in
                        NSError(domain: "evidence.primary", code: index, userInfo: [NSLocalizedDescriptionKey: "primary \(index)",
                            NSUnderlyingErrorKey: NSError(domain: "evidence.cause", code: index)])
                    }
                    let scope = DebugBundleEvidenceScope(operationId: UUID().uuidString.lowercased())
                    let failures = errors.map { _ in UUID().uuidString.lowercased() }
                    let contexts = failures.map { DebugBundleEvidenceContext.forFailure($0, scope: scope) }
                    let observations = failures.map { DebugBundleRecoveryObservation(failureRef: $0,
                        attemptId: UUID().uuidString.lowercased(), state: "attempt_completed", scope: scope, statusCode: 200) }
                    let before = heapSnapshot()
                    let start = DispatchTime.now().uptimeNanoseconds
                    // Include disposal of caller temporaries; setup temporaries
                    // must not inflate the retained-memory comparison.
                    autoreleasepool {
                        for index in 0..<pairs {
                            client.captureException(errors[index], context: contexts[index])
                            client.captureRecovery(observations[index])
                        }
                    }
                    let captureTime = DispatchTime.now().uptimeNanoseconds - start
                    let capturedHeap = heapSnapshot()
                    let retainedCount = client.pendingCaptureCount
                    let retainedBytes = client.pendingCaptureBytes
                    XCTAssertLessThanOrEqual(retainedCount, 256)
                    XCTAssertLessThanOrEqual(retainedBytes, 2 * 1024 * 1024)
                    let deferredStart = DispatchTime.now().uptimeNanoseconds
                    store.release.signal()
                    await client.flush()
                    await client.waitForPendingCapture()
                    let deferredTime = DispatchTime.now().uptimeNanoseconds - deferredStart
                    let finalHeap = heapSnapshot()
                    let events = await transport.recordedBatches().flatMap { $0 }
                    let primary = events.filter { $0.eventType == "frontend_exception" }
                    XCTAssertEqual(primary.count, pairs)
                    for event in primary {
                        XCTAssertEqual(event.payload["exception_evidence"] != nil, enabled)
                        if enabled { XCTAssertEqual(event.payload["exception_evidence"]?.objectValue?["nodes"]?.arrayValue?.count, 2) }
                    }
                    let observationsDelivered = events.filter { $0.eventType == "diagnostic_context" }
                    XCTAssertEqual(observationsDelivered.count, enabled && !pressure ? pairs : 0)
                    let diagnosticBytes = try observationsDelivered.reduce(0) { try $0 + JSONEncoder().encode($1).count }
                    XCTAssertLessThanOrEqual(diagnosticBytes, 65536)
                    withExtendedLifetime(errors) {}
                    if repetition > 0 {
                        let result: [String: Any] = ["repeat": repetition, "evidence": enabled, "pressure": pressure, "pairs": pairs,
                            "capture_ns_per_pair": Double(captureTime) / Double(pairs), "deferred_flush_ns": deferredTime,
                            "capture_live_malloc_bytes_delta": capturedHeap.bytes - before.bytes,
                            "capture_live_malloc_blocks_delta": capturedHeap.blocks - before.blocks,
                            "total_live_malloc_bytes_delta": finalHeap.bytes - before.bytes,
                            "capture_live_malloc_bytes": capturedHeap.bytes,
                            "process_malloc_high_water_bytes": finalHeap.peak,
                            "retained_count": retainedCount, "retained_wire_bytes": retainedBytes,
                            "delivered_diagnostic_bytes": diagnosticBytes]
                        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
                    }
                }
            }
        }
    }

    // Live Darwin allocator deltas include process activity; they are neither
    // cumulative allocation churn nor whole-process RSS/physical-memory peaks.
    private func heapSnapshot() -> (bytes: Int64, blocks: Int64, peak: Int64) {
        var value = malloc_statistics_t()
        malloc_zone_statistics(nil, &value)
        return (Int64(value.size_in_use), Int64(value.blocks_in_use), Int64(value.max_size_in_use))
    }
}

private final class PerformanceQueueStore: DebugBundleQueueStoring {
    let entered = XCTestExpectation(description: "isolated queue startup held")
    let release = DispatchSemaphore(value: 0)
    func load(now: Date, ttl: TimeInterval) -> [DebugBundleEventEnvelope] {
        entered.fulfill()
        _ = release.wait(timeout: .now() + 60)
        return []
    }
    func persist(_ events: [DebugBundleEventEnvelope]) {}
}

private struct PerformancePolicy: DebugBundleRemoteConfigClienting {
    func fetch(request: DebugBundleRemoteConfigRequest) async -> DebugBundleRemoteConfigResult {
        var policy = DebugBundleRemoteCapturePolicy(preset: "balanced")
        policy.captureDiagnosticContext = true
        return .loaded(.init(capturePolicy: policy), eTag: nil)
    }
}
