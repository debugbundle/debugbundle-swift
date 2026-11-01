import Foundation
import XCTest
import DebugBundleTestSupport
@testable import DebugBundle

final class DebugBundleRecoveryEvidenceTests: XCTestCase {
    func testIndependentRecoveryPreservesScopeAndFinalHookIdentityThroughAcknowledgement() async throws {
        let transport = RecordingTransport()
        let failure = UUID().uuidString.lowercased(), attempt = UUID().uuidString.lowercased(), replacement = UUID().uuidString.lowercased()
        let config = DebugBundleConfig(projectToken: "fictional", service: "ios", batchSize: 10, flushInterval: 60,
            beforeSend: { input in
                var event = input
                if event.eventType == "diagnostic_context" { event.eventId = replacement }
                return event
            }).withEvidenceOptions(.init(captureRecoveryObservations: true,
                evidenceCapabilities: .init(features: DebugBundleEvidenceCapabilities.known)))
        let client = makeIsolatedClient(config: config, transport: transport, remoteConfigClient: RecoveryPolicyConfig(), random: { 0 })
        await client.refreshRemoteConfig()
        var scope: DebugBundleEvidenceScope?
        client.withOperationContext {
            scope = client.evidence.operations.current()
            client.captureException(NSError(domain: "fictional", code: 1), context: DebugBundleEvidenceContext.forFailure(failure))
            client.captureRecovery(.init(failureRef: failure, attemptId: attempt, state: "recovery_observed", operation: "reload"))
        }
        await client.flush()
        let events = await transport.recordedBatches().flatMap { $0 }
        XCTAssertEqual(events.count, 2)
        let primary = try XCTUnwrap(events.first { $0.eventType == "frontend_exception" })
        let observation = try XCTUnwrap(events.first { $0.eventType == "diagnostic_context" })
        XCTAssertEqual(primary.context?["evidence_reference"]?.objectValue?["scope"], scope?.wire)
        XCTAssertEqual(observation.payload["scope"], scope?.wire)
        XCTAssertEqual(observation.payload["state"], .string("recovery_observed"))
        XCTAssertEqual(observation.eventId, replacement)
        XCTAssertTrue(isValidBeforeSendEvent(observation))
        XCTAssertFalse(client.evidence.budget.eligible(observation), "ACK releases pending bytes while retaining allowances")
    }

    func testLatestHookIdentityIsReleasedAfterSamplingExpiryAndQueueSizeDrops() async {
        for mode in ["sampling", "expiry", "size"] {
            let clock = RecoveryEvidenceClock()
            let box = RecoveryEvidenceEvents()
            let transport = RecordingTransport()
            let config = DebugBundleConfig(projectToken: "fictional", service: "ios", flushInterval: 60,
                sampleRate: mode == "sampling" ? 0 : 1, offlineQueueMaxBytes: mode == "size" ? 1024 : 262_144,
                offlineQueueTtl: 60, beforeSend: { input in
                    guard input.eventType == "diagnostic_context" else { return input }
                    var event = input
                    event.eventId = UUID().uuidString.lowercased()
                    if mode == "expiry" { clock.advance(61) }
                    if mode == "size" { event.context = ["detail": .string(String(repeating: "x", count: 1024))] }
                    box.store(input, event)
                    return event
                }).withEvidenceOptions(.init(captureRecoveryObservations: true, evidenceCapabilities: .init(features: ["recovery_v1"])))
            let client = makeIsolatedClient(config: config, transport: transport, remoteConfigClient: RecoveryPolicyConfig(), clock: clock.now, random: { 0.5 })
            await client.refreshRemoteConfig()
            client.captureRecovery(.init(failureRef: UUID().uuidString.lowercased(), attemptId: UUID().uuidString.lowercased(),
                state: "attempt_started", scope: .init(operationId: UUID().uuidString.lowercased())))
            await client.flush()
            let events = await transport.recordedBatches().flatMap { $0 }
            XCTAssertFalse(events.contains { $0.eventType == "diagnostic_context" }, mode)
            let observed = box.events
            XCTAssertEqual(observed.count, 2, mode)
            for event in observed { XCTAssertFalse(client.evidence.budget.eligible(event), "Orphaned \(mode) identity") }
        }
    }

    func testOfflineRecoveryHoldsDuringUnknownPolicyWithoutBlockingOrdinaryFailureOrRenewingWindow() async throws {
        let clock = RecoveryEvidenceClock()
        let scope = DebugBundleEvidenceScope(operationId: UUID().uuidString.lowercased())
        let failure = UUID().uuidString.lowercased()
        let observation = DebugBundleEventEnvelope(sdkName: "@debugbundle/sdk-swift", sdkVersion: "3.0.1", service: "ios", environment: "production",
            eventType: "diagnostic_context", occurredAt: debugBundleTimestamp(clock.now()),
            correlation: .init(requestId: nil, traceId: nil, sessionId: "0", userIdHash: nil),
            payload: ["version": .number(1), "kind": .string("recovery"), "failure_ref": .string(failure), "scope": scope.wire!,
                "attempt_id": .string(UUID().uuidString.lowercased()), "state": .string("attempt_completed"), "status_code": .number(200)],
            device: .init(), releaseChannel: "test", appVersion: nil, buildNumber: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = directory.appendingPathComponent("queue.json")
        DebugBundleFileQueueStore(fileURL: queue).persist([observation])
        let policy = RecoveryMutablePolicy()
        let transport = RecordingTransport()
        let config = DebugBundleConfig(projectToken: "fictional", service: "ios", flushInterval: 60, offlineQueueURL: queue)
            .withEvidenceOptions(.init(captureRecoveryObservations: true, evidenceCapabilities: .init(features: ["recovery_v1"])))
        let client = makeIsolatedClient(config: config, transport: transport, remoteConfigClient: policy, clock: clock.now, random: { 0 })
        await client.waitForPendingCapture()
        client.captureLog("ordinary failure", level: .error)
        await client.flush()
        let first = await transport.recordedBatches().flatMap { $0 }
        XCTAssertEqual(first.map(\.eventType), ["log_event"])
        XCTAssertTrue(client.evidence.budget.eligible(observation))
        clock.advance(301)
        policy.loadBalanced()
        await client.refreshRemoteConfig()
        client.captureRecovery(.init(failureRef: failure, attemptId: UUID().uuidString.lowercased(), state: "recovery_observed", scope: scope, sessionId: "0"))
        await client.flush()
        let delivered = await transport.recordedBatches().flatMap { $0 }.filter { $0.eventType == "diagnostic_context" }
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.occurredAt, observation.occurredAt)
        XCTAssertEqual(delivered.first?.payload["state"], .string("attempt_completed"))
        XCTAssertEqual(delivered.first?.correlation?.sessionId, "0")
        XCTAssertFalse(client.evidence.budget.eligible(observation))
    }

    func testStartupRetainsOnlyLocallyEnabledBudgetOwnedDiagnosticEnvelopes() async throws {
        for enabled in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let queue = directory.appendingPathComponent("queue.json")
            let events = (0..<70).map { _ in DebugBundleEventEnvelope(sdkName: "@debugbundle/sdk-swift", sdkVersion: "3.0.1", service: "ios", environment: "production",
                eventType: "diagnostic_context", occurredAt: debugBundleTimestamp(Date()), correlation: nil,
                payload: ["version": .number(1), "kind": .string("recovery"), "failure_ref": .string(UUID().uuidString.lowercased()),
                    "scope": DebugBundleEvidenceScope(operationId: UUID().uuidString.lowercased()).wire!,
                    "attempt_id": .string(UUID().uuidString.lowercased()), "state": .string("attempt_started")],
                device: .init(), releaseChannel: "test", appVersion: nil, buildNumber: nil) }
            DebugBundleFileQueueStore(fileURL: queue).persist(events)
            let config = DebugBundleConfig(projectToken: "fictional", service: "ios", flushInterval: 60, offlineQueueURL: queue)
                .withEvidenceOptions(.init(captureRecoveryObservations: enabled, evidenceCapabilities: .init(features: ["recovery_v1"])))
            let client = makeIsolatedClient(config: config, transport: RecordingTransport(), random: { 0 })
            await client.waitForPendingCapture()
            let retained = try DebugBundleQueueInspector.loadEvents(from: queue)
            if enabled {
                XCTAssertLessThanOrEqual(retained.count, 50)
                XCTAssertTrue(retained.allSatisfy { client.evidence.budget.eligible($0) })
            } else { XCTAssertTrue(retained.isEmpty) }
        }
    }

    func testRecoveryRequiresLocalOptInAndPermittedPolicy() async {
        for (enabled, preset, diagnostics) in [(false, "balanced", true), (true, "minimal", true), (true, "balanced", false)] {
            let transport = RecordingTransport()
            let config = DebugBundleConfig(projectToken: "fictional", service: "ios", flushInterval: 60)
                .withEvidenceOptions(.init(captureRecoveryObservations: enabled, evidenceCapabilities: .init(features: ["recovery_v1"])))
            let client = makeIsolatedClient(config: config, transport: transport,
                remoteConfigClient: RecoveryPolicyConfig(preset: preset, diagnostics: diagnostics), random: { 0 })
            await client.refreshRemoteConfig()
            client.captureRecovery(.init(failureRef: UUID().uuidString.lowercased(), attemptId: UUID().uuidString.lowercased(),
                state: "attempt_completed", scope: .init(operationId: UUID().uuidString.lowercased()), statusCode: 200))
            await client.flush()
            let events = await transport.recordedBatches().flatMap { $0 }
            XCTAssertTrue(events.isEmpty)
        }
    }
}

private struct RecoveryPolicyConfig: DebugBundleRemoteConfigClienting {
    var preset = "balanced"
    var diagnostics = true
    func fetch(request: DebugBundleRemoteConfigRequest) async -> DebugBundleRemoteConfigResult {
        var policy = DebugBundleRemoteCapturePolicy(preset: preset)
        policy.captureDiagnosticContext = diagnostics
        return .loaded(.init(capturePolicy: policy), eTag: nil)
    }
}

private final class RecoveryEvidenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}
private final class RecoveryEvidenceEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DebugBundleEventEnvelope] = []
    var events: [DebugBundleEventEnvelope] { lock.withLock { values } }
    func store(_ original: DebugBundleEventEnvelope, _ replacement: DebugBundleEventEnvelope) { lock.withLock { values += [original, replacement] } }
}
private final class RecoveryMutablePolicy: DebugBundleRemoteConfigClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var result = DebugBundleRemoteConfigResult.failed
    func loadBalanced() { lock.withLock { result = .loaded(.init(capturePolicy: .init(preset: "balanced")), eTag: nil) } }
    func fetch(request: DebugBundleRemoteConfigRequest) async -> DebugBundleRemoteConfigResult { lock.withLock { result } }
}
