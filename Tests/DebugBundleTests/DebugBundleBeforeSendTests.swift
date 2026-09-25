import Foundation
import XCTest
@testable import DebugBundle
import DebugBundleTestSupport

final class DebugBundleBeforeSendTests: XCTestCase {
    func testFilteredInfoBurstDoesNotInvokeHook() {
        let hooks = LockedCounter()
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "ios", logLevel: .warning,
                beforeSend: { event in
                    hooks.increment()
                    return event
                }),
            transport: RecordingTransport(), connectivityMonitor: nil, random: { 0 }
        )

        for index in 0 ..< 10_000 {
            client.captureLog("filtered info \(index)", level: .info)
        }
        XCTAssertEqual(hooks.value, 0)
    }

    func testContextIsCopiedBeforeRetentionAndServiceMetadataIsProtected() async {
        let transport = RecordingTransport()
        let client = DebugBundleClient(config: DebugBundleConfig(projectToken: "token", service: "ios", batchSize: 10, flushInterval: 60,
            beforeSend: { event in
                var changed = event
                changed.serviceRuntime = "dbundle_proj_RUNTIME_SECRET"
                changed.serviceFramework = "token=FRAMEWORK_SECRET"
                return changed
            }), transport: transport, connectivityMonitor: nil, random: { 0 })
        let context = NSMutableDictionary(dictionary: ["route": "/checkout", "password": "CONTEXT_SECRET"])
        client.setContext("checkout", value: context)
        context["route"] = "/changed-after-retention"
        client.captureLog("safe", level: .error)
        await client.flush()
        let event = await transport.recordedBatches().flatMap { $0 }.first
        XCTAssertEqual(event?.serviceRuntime, "[REDACTED]")
        XCTAssertEqual(event?.serviceFramework, "token=[REDACTED]")
        let checkout = event?.payload["attributes"]?.objectValue?["checkout"]?.objectValue
        XCTAssertEqual(checkout?["route"], .string("/checkout"))
        XCTAssertEqual(checkout?["password"], .string("[REDACTED]"))
    }

    func testHookCannotReintroduceCredentialsThroughProtocolMetadata() async {
        let transport = RecordingTransport()
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "ios", batchSize: 10, flushInterval: 60,
                beforeSend: { event in
                    var changed = event
                    changed.sdkVersion = "dbundle_proj_SYNTHETIC_SECRET"
                    return changed
                }),
            transport: transport, connectivityMonitor: nil, random: { 0 }
        )
        client.captureLog("safe", level: .error)
        await client.flush()
        let events = await transport.recordedBatches().flatMap { $0 }
        XCTAssertTrue(events.isEmpty)
    }

    func testBeforeSendValidatesEveryClosedEventPayload() {
        let base = DebugBundleEventEnvelope(
            sdkName: "@debugbundle/sdk-swift",
            sdkVersion: "1.1.0",
            service: "checkout-ios",
            environment: "production",
            eventType: DebugBundleEventType.logEvent,
            occurredAt: "2026-05-29T10:00:00.123Z",
            correlation: nil,
            payload: [:],
            device: DebugBundleDeviceContext(),
            releaseChannel: "app-store",
            appVersion: nil,
            buildNumber: nil
        )
        let payloads: [(String, [String: JSONValue])] = [
            (
                DebugBundleEventType.frontendException,
                [
                    "name": .string("Error"),
                    "message": .string("failed"),
                    "stack": .string("stack"),
                    "device": .object([:])
                ]
            ),
            (
                DebugBundleEventType.frontendBreadcrumb,
                [
                    "breadcrumb_type": .string("custom"),
                    "data": .object([:]),
                    "device": .object([:])
                ]
            ),
            (
                DebugBundleEventType.logEvent,
                [
                    "level": .string("error"),
                    "message": .string("failed"),
                    "attributes": .object([:]),
                    "device": .object([:])
                ]
            ),
            (
                DebugBundleEventType.requestEvent,
                [
                    "method": .string("POST"),
                    "path": .string("/checkout"),
                    "query": .object([:]),
                    "headers": .object([:]),
                    "response_status": .number(503),
                    "duration_ms": .number(20),
                    "device": .object([:])
                ]
            ),
            (
                DebugBundleEventType.errorSuppressed,
                [
                    "fingerprint": .string("fingerprint"),
                    "suppressed_count": .number(2),
                    "window_seconds": .number(60),
                    "first_seen": .string("2026-05-29T10:00:00Z"),
                    "last_seen": .string("2026-05-29T10:00:01Z"),
                    "device": .object([:])
                ]
            ),
            (
                DebugBundleEventType.probeEvent,
                [
                    "label": .string("checkout.total"),
                    "data": .object(["value": .number(42)]),
                    "activation_id": .null,
                    "probe_label_pattern": .string("checkout.*"),
                    "device": .object([:])
                ]
            )
        ]

        for (eventType, payload) in payloads {
            var event = base
            event.eventType = eventType
            event.payload = payload
            XCTAssertEqual(applyDebugBundleBeforeSend(event, hook: { $0 }), event)
        }

        var unknown = base
        unknown.eventType = "unknown"
        XCTAssertEqual(applyDebugBundleBeforeSend(unknown, hook: { $0 }), unknown)

        for mutate in [
            { (event: inout DebugBundleEventEnvelope) in event.schemaVersion = "invalid" },
            { (event: inout DebugBundleEventEnvelope) in event.eventId = "invalid" },
            { (event: inout DebugBundleEventEnvelope) in event.sdkName = "" },
            { (event: inout DebugBundleEventEnvelope) in event.sdkVersion = "" },
            { (event: inout DebugBundleEventEnvelope) in event.service = "" },
            { (event: inout DebugBundleEventEnvelope) in event.environment = "" },
            { (event: inout DebugBundleEventEnvelope) in event.occurredAt = "invalid" }
        ] {
            var invalid = base
            invalid.payload = [
                "level": .string("error"),
                "message": .string("failed"),
                "attributes": .object([:])
            ]
            mutate(&invalid)
            XCTAssertEqual(applyDebugBundleBeforeSend(invalid, hook: { $0 }), invalid)
        }

        var extraKey = base
        extraKey.payload = [
            "level": .string("error"),
            "message": .string("failed"),
            "attributes": .object([:]),
            "extra": .bool(true)
        ]
        XCTAssertEqual(applyDebugBundleBeforeSend(extraKey, hook: { $0 }), extraKey)
        XCTAssertEqual(applyDebugBundleBeforeSend(base, hook: nil), base)
        XCTAssertNil(applyDebugBundleBeforeSend(base, hook: { _ in nil }))
    }

    func testBeforeSendRunsAfterRedactionOnlyForEligibleLogs() async {
        let observation = LockedObservation()
        let transport = RecordingTransport()
        let client = DebugBundleClient(
            config: DebugBundleConfig(
                projectToken: "token",
                service: "checkout-ios",
                beforeSend: { event in
                    observation.value = event.payload["attributes"]?
                        .objectValue?["password"]
                    return event
                }
            ),
            transport: transport,
            connectivityMonitor: nil,
            random: { 0 }
        )

        client.captureLog("eligible", level: .error, context: ["password": "secret"])
        await client.flush()

        XCTAssertEqual(observation.value, .string("[REDACTED]"))
        let batches = await transport.recordedBatches()
        XCTAssertEqual(batches.flatMap { $0 }.count, 1)

        let filteredObservation = LockedObservation()
        let filteredTransport = RecordingTransport()
        let filteredClient = DebugBundleClient(
            config: DebugBundleConfig(
                projectToken: "token",
                service: "checkout-ios",
                captureLogs: false,
                beforeSend: { event in
                    filteredObservation.value = event.payload["attributes"]?
                        .objectValue?["password"]
                    return event
                }
            ),
            transport: filteredTransport,
            connectivityMonitor: nil,
            random: { 0 }
        )
        filteredClient.captureLog("disabled", level: .error, context: ["password": "secret"])
        await filteredClient.flush()
        XCTAssertNil(filteredObservation.value)
        let filteredBatches = await filteredTransport.recordedBatches()
        XCTAssertTrue(filteredBatches.flatMap { $0 }.isEmpty)
    }

    func testBeforeSendMutatesDropsAndRejectsInvalidResults() async throws {
        let transport = RecordingTransport()
        let client = DebugBundleClient(
            config: DebugBundleConfig(
                projectToken: "token",
                service: "checkout-ios",
                batchSize: 10,
                flushInterval: 60,
                beforeSend: { event in
                    if event.payload["message"] == .string("drop") {
                        return nil
                    }
                    if event.payload["message"] == .string("invalid") {
                        var invalid = event
                        invalid.eventId = "invalid"
                        return invalid
                    }
                    var mutated = event
                    if mutated.payload["message"] == .string("mutate") {
                        mutated.payload["message"] = .string("mutated")
                    }
                    return mutated
                }
            ),
            transport: transport,
            connectivityMonitor: nil,
            random: { 0 }
        )

        client.captureLog("mutate", level: .error)
        client.captureLog("drop", level: .error)
        client.captureLog("invalid", level: .error)
        await client.flush()

        let events = await transport.recordedBatches().flatMap { $0 }
        XCTAssertEqual(events.map { $0.payload["message"] }, [
            .string("mutated"),
            .string("invalid")
        ])
        XCTAssertNotEqual(try XCTUnwrap(events.last).eventId, "invalid")
    }

    func testBeforeSendCannotReintroduceCredentialText() async {
        let transport = RecordingTransport()
        let client = DebugBundleClient(
            config: DebugBundleConfig(
                projectToken: "token",
                service: "checkout-ios",
                batchSize: 10,
                beforeSend: { event in
                    var changed = event
                    changed.payload["message"] = .string("Failure token=hook-secret")
                    return changed
                }
            ),
            transport: transport,
            connectivityMonitor: nil,
            random: { 0 }
        )
        client.captureLog("original", level: .error)
        await client.flush()
        let events = await transport.recordedBatches().flatMap { $0 }
        XCTAssertEqual(events.first?.payload["message"], .string("Failure token=[REDACTED]"))
    }

    func testLogFingerprintIgnoresCaptureTimeButRetainsApplicationContext() {
        let first: [String: JSONValue] = ["level": .string("error"), "message": .string("duplicate"),
            "attributes": .object(["logged_at": .string("2026-09-21T00:00:00Z"), "route": .string("/checkout")])]
        var later = first
        later["attributes"] = .object(["logged_at": .string("2026-09-21T00:00:01Z"), "route": .string("/checkout")])
        XCTAssertEqual(debugBundleFingerprint(eventType: DebugBundleEventType.logEvent, payload: first),
                       debugBundleFingerprint(eventType: DebugBundleEventType.logEvent, payload: later))
        later["attributes"] = .object(["route": .string("/orders")])
        XCTAssertNotEqual(debugBundleFingerprint(eventType: DebugBundleEventType.logEvent, payload: first),
                          debugBundleFingerprint(eventType: DebugBundleEventType.logEvent, payload: later))
    }

    func testBeforeSendAppliesToSuppressionAggregates() async {
        let transport = RecordingTransport()
        let client = DebugBundleClient(
            config: DebugBundleConfig(
                projectToken: "token",
                service: "checkout-ios",
                batchSize: 20,
                flushInterval: 60,
                offlineQueueURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathComponent("queue.json"),
                beforeSend: { event in
                    guard event.eventType == DebugBundleEventType.errorSuppressed else {
                        return event
                    }
                    var mutated = event
                    mutated.payload["fingerprint"] = .string("hooked-aggregate")
                    return mutated
                }
            ),
            transport: transport,
            connectivityMonitor: nil,
            random: { 0 }
        )

        for _ in 0 ..< 4 {
            client.captureLog("duplicate", level: .error)
        }
        await client.flush()

        let events = await transport.recordedBatches().flatMap { $0 }
        let aggregate = events.first { $0.eventType == DebugBundleEventType.errorSuppressed }
        XCTAssertEqual(aggregate?.payload["fingerprint"], .string("hooked-aggregate"), "Captured: \(events.map { ($0.eventType, debugBundleFingerprint(eventType: $0.eventType, payload: $0.payload)) })")
    }
}

private final class LockedObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: JSONValue?

    var value: JSONValue? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
