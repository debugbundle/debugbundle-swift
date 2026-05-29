import XCTest
@testable import DebugBundle
import DebugBundleTestSupport
import DebugBundleSwiftLog
import Logging

final class DebugBundleClientTests: XCTestCase {
    func testMissingTokenLeavesClientDisconnectedAndSilent() async {
        let transport = RecordingTransport()
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "", enabled: true, service: "checkout-ios"),
            transport: transport,
            random: { 0 }
        )

        client.captureMessage("hello")
        await client.flush()

        XCTAssertEqual(client.status, DebugBundleStatus.disconnected)
        let batches = await transport.recordedBatches()
        XCTAssertTrue(batches.isEmpty)
    }

    func testCaptureExceptionRedactsSensitiveContextAndAttachesBreadcrumbsAndProbes() async throws {
        let transport = RecordingTransport()
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios"),
            transport: transport,
            random: { 0 },
            deviceContextProvider: {
                DebugBundleDeviceContext(appVersion: "1.2.3", releaseChannel: "app-store", osName: "iOS", osVersion: "18")
            }
        )

        client.setContext("account_id", value: "acct_123")
        client.recordBreadcrumb(breadcrumbType: "screen_transition", route: "Checkout", data: ["previous_screen": "Cart"])
        client.probe("checkout.cart", data: ["password": "secret", "items": 3])
        client.captureException(
            NSError(domain: "Test", code: 42, userInfo: [NSLocalizedDescriptionKey: "boom"]),
            context: [
                "authorization": "Bearer secret",
                "nested": ["password": "super-secret"]
            ]
        )

        await client.flush()

        let batches = await transport.recordedBatches()
        let event = try XCTUnwrap(batches.first?.first)
        XCTAssertEqual(event.eventType, DebugBundleEventType.frontendException)
        let context = event.payload["context"]?.objectValue
        XCTAssertEqual(context?["authorization"], .string("[REDACTED]"))
        XCTAssertEqual(context?["account_id"], .string("acct_123"))
        XCTAssertEqual(context?["nested"]?.objectValue?["password"], .string("[REDACTED]"))

        let breadcrumbs = event.payload["breadcrumbs"]?.arrayValue
        XCTAssertEqual(breadcrumbs?.count, 1)
        XCTAssertEqual(event.payload["probe_data"]?.objectValue?["checkout.cart"]?.arrayValue?.first?.objectValue?["password"], .string("[REDACTED]"))
        XCTAssertEqual(event.device.releaseChannel, "app-store")
        XCTAssertEqual(client.status, .healthy)
    }

    func testCaptureAsyncReportsAndRethrows() async throws {
        struct SampleError: LocalizedError {
            var errorDescription: String? { "async failed" }
        }

        let transport = RecordingTransport()
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios"),
            transport: transport,
            random: { 0 }
        )

        do {
            _ = try await client.captureAsync(context: ["operation": "payment_refresh"]) {
                throw SampleError()
            }
            XCTFail("expected error")
        } catch {
            XCTAssertEqual((error as NSError).localizedDescription, "async failed")
        }

        await client.flush()

        let batches = await transport.recordedBatches()
        let event = try XCTUnwrap(batches.first?.first)
        XCTAssertEqual(event.eventType, DebugBundleEventType.frontendException)
        XCTAssertEqual(event.payload["context"]?.objectValue?["operation"], .string("payment_refresh"))
        XCTAssertEqual(event.payload["error"]?.objectValue?["message"], .string("async failed"))
    }

    func testCaptureTaskReportsErrorAndReturnsNil() async throws {
        struct SampleError: LocalizedError {
            var errorDescription: String? { "task failed" }
        }

        let transport = RecordingTransport()
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios"),
            transport: transport,
            random: { 0 }
        )

        let value: String? = await client.captureTask {
            throw SampleError()
        }.value

        XCTAssertNil(value)

        await client.flush()

        let batches = await transport.recordedBatches()
        let event = try XCTUnwrap(batches.first?.first)
        XCTAssertEqual(event.eventType, DebugBundleEventType.frontendException)
        XCTAssertEqual(event.payload["error"]?.objectValue?["message"], .string("task failed"))
    }

    func testRequestCaptureFiltersHeadersAndPromotesServerErrors() async throws {
        let transport = RecordingTransport()
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios"),
            transport: transport,
            random: { 0 }
        )

        client.captureRequest(
            DebugBundleRequestInfo(
                method: "POST",
                url: "https://api.example.com/checkout",
                routeTemplate: "/checkout",
                headers: [
                    "Authorization": "Bearer secret",
                    "Accept": "application/json",
                    "User-Agent": "debugbundle-test"
                ],
                traceId: "trace-123"
            ),
            response: DebugBundleResponseInfo(
                statusCode: 503,
                durationMillis: 120,
                headers: [
                    "Traceparent": "00-abc-123-01",
                    "Set-Cookie": "session=secret"
                ]
            )
        )

        await client.flush()

        let batches = await transport.recordedBatches()
        let event = try XCTUnwrap(batches.first?.first)
        XCTAssertEqual(event.eventType, DebugBundleEventType.requestEvent)
        XCTAssertEqual(event.correlation?.traceId, "trace-123")
        XCTAssertEqual(event.payload["headers"]?.objectValue?.keys.sorted(), ["accept", "user-agent"])
        XCTAssertEqual(event.payload["response_headers"]?.objectValue?.keys.sorted(), ["traceparent"])
    }

    func testDuplicateSuppressionEmitsAggregateAfterThirdIdenticalEvent() async throws {
        let transport = RecordingTransport()
        let fixedDate = Date(timeIntervalSince1970: 1_000)
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios"),
            transport: transport,
            clock: { fixedDate },
            random: { 0 }
        )

        for _ in 0 ..< 4 {
            client.captureMessage("duplicate", level: .error)
        }

        await client.flush()

        let events = await transport.recordedBatches().flatMap { $0 }
        XCTAssertEqual(events.map(\ .eventType), [
            DebugBundleEventType.logEvent,
            DebugBundleEventType.logEvent,
            DebugBundleEventType.logEvent,
            DebugBundleEventType.errorSuppressed
        ])
        XCTAssertEqual(events.last?.payload["suppressed_count"], .number(1))
    }

    func testLoopProtectionEmitsCheckpointAndResetsAfterSilenceWindow() async throws {
        let transport = RecordingTransport()
        var currentTime = Date(timeIntervalSince1970: 1_000)
        let error = NSError(domain: "Loop", code: 42, userInfo: [NSLocalizedDescriptionKey: "looping failure"])
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios", batchSize: 100),
            transport: transport,
            clock: { currentTime },
            random: { 0 }
        )

        for _ in 0 ..< 11 {
            client.captureError(error)
        }

        currentTime = currentTime.addingTimeInterval(1)
        client.captureError(error)

        currentTime = currentTime.addingTimeInterval(30)
        client.captureError(error)

        currentTime = currentTime.addingTimeInterval(61)
        client.captureError(error)

        await client.flush()

        let events = await transport.recordedBatches().flatMap { $0 }
        let suppressedEvents = events.filter { $0.eventType == DebugBundleEventType.errorSuppressed }
        let trailingSuppressedCounts = suppressedEvents.suffix(2).compactMap { $0.payload["suppressed_count"] }
        XCTAssertEqual(events.count, 13)
        XCTAssertEqual(events.prefix(3).map(\.eventType), [
            DebugBundleEventType.frontendException,
            DebugBundleEventType.frontendException,
            DebugBundleEventType.frontendException
        ])
        XCTAssertEqual(suppressedEvents.count, 9)
        XCTAssertEqual(trailingSuppressedCounts, [.number(8), .number(10)])
        XCTAssertEqual(events.last?.eventType, DebugBundleEventType.frontendException)
        XCTAssertEqual(events.last?.payload["error"]?.objectValue?["message"], .string("looping failure"))
    }

    func testRemoteCapturePolicySuppressesWarningLogsWhenServerRequiresErrorsOnly() async throws {
        let transport = RecordingTransport()
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios"),
            transport: transport,
            remoteConfigClient: StaticRemoteConfigClient(
                result: .loaded(
                    DebugBundleRemoteConfigResponse(
                        capturePolicy: DebugBundleRemoteCapturePolicy(
                            preset: "minimal",
                            captureLogs: "error",
                            captureRequestEvents: "failures_only",
                            captureBreadcrumbs: "local_only",
                            captureProbeEvents: "buffer_only"
                        )
                    ),
                    eTag: "tag-1"
                )
            ),
            random: { 0 }
        )

        await client.refreshRemoteConfig()
        client.captureLog("warning suppressed", level: .warning)
        client.captureLog("error kept", level: .error)
        await client.flush()

        let batches = await transport.recordedBatches()
        let messages = batches.flatMap { $0 }.compactMap { $0.payload["message"] }
        XCTAssertEqual(messages, [.string("error kept")])
    }

    func testRequestPolicyOffSuppressesStandaloneRequestEventButRetainsBreadcrumbForException() async throws {
        let transport = RecordingTransport()
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios"),
            transport: transport,
            remoteConfigClient: StaticRemoteConfigClient(
                result: .loaded(
                    DebugBundleRemoteConfigResponse(
                        capturePolicy: DebugBundleRemoteCapturePolicy(
                            preset: "minimal",
                            captureLogs: "error",
                            captureRequestEvents: "off",
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
        client.captureRequest(
            DebugBundleRequestInfo(method: "GET", url: "https://api.example.com/checkout"),
            response: DebugBundleResponseInfo(statusCode: 200, durationMillis: 42)
        )
        client.captureException(NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"]))
        await client.flush()

        let batches = await transport.recordedBatches()
        let events = batches.flatMap { $0 }
        XCTAssertEqual(events.map(\.eventType), [DebugBundleEventType.frontendException])
        XCTAssertEqual(events.first?.payload["breadcrumbs"]?.arrayValue?.count, 1)
    }

    func testStandaloneBreadcrumbPolicyEmitsFrontendBreadcrumbEvents() async throws {
        let transport = RecordingTransport()
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios"),
            transport: transport,
            remoteConfigClient: StaticRemoteConfigClient(
                result: .loaded(
                    DebugBundleRemoteConfigResponse(
                        capturePolicy: DebugBundleRemoteCapturePolicy(
                            preset: "investigative",
                            captureLogs: "info",
                            captureRequestEvents: "all",
                            captureBreadcrumbs: "standalone",
                            captureProbeEvents: "standalone_when_activated"
                        )
                    ),
                    eTag: nil
                )
            ),
            random: { 0 }
        )

        await client.refreshRemoteConfig()
        client.recordBreadcrumb(breadcrumbType: "screen_transition", route: "Checkout")
        await client.flush()

        let batches = await transport.recordedBatches()
        let event = try XCTUnwrap(batches.first?.first)
        XCTAssertEqual(event.eventType, DebugBundleEventType.frontendBreadcrumb)
        XCTAssertEqual(event.payload["breadcrumb_type"], .string("screen_transition"))
    }

    func testActivatedRemoteProbeEmitsStandaloneProbeEventAndHeavyProbeRunsOnlyWhenActivated() async throws {
        let transport = RecordingTransport()
        let expiry = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 4_000))
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", environment: "production", service: "checkout-ios"),
            transport: transport,
            remoteConfigClient: StaticRemoteConfigClient(
                result: .loaded(
                    DebugBundleRemoteConfigResponse(
                        probesEnabled: true,
                        remoteProbesEnabled: true,
                        activeProbes: [
                            DebugBundleRemoteProbeDirective(
                                activationId: "act-1",
                                labelPattern: "checkout.*",
                                service: "checkout-ios",
                                environment: "production",
                                expiresAt: expiry,
                                triggerExpiresAt: expiry
                            )
                        ],
                        capturePolicy: DebugBundleRemoteCapturePolicy(
                            preset: "investigative",
                            captureLogs: "info",
                            captureRequestEvents: "all",
                            captureBreadcrumbs: "standalone",
                            captureProbeEvents: "standalone_when_activated"
                        )
                    ),
                    eTag: nil
                )
            ),
            clock: { Date(timeIntervalSince1970: 3_000) },
            random: { 0 }
        )

        await client.refreshRemoteConfig()
        var heavyProbeRan = false
        client.probe("checkout.tax", data: ["rate": 0.2])
        client.probe("checkout.tax", options: ProbeOptions(heavy: true)) {
            heavyProbeRan = true
            return ["calculation": "expensive"]
        }
        await client.flush()

        let batches = await transport.recordedBatches()
        let events = batches.flatMap { $0 }
        XCTAssertTrue(heavyProbeRan)
        XCTAssertEqual(events.map(\.eventType), [DebugBundleEventType.probeEvent, DebugBundleEventType.probeEvent])
        XCTAssertEqual(events.first?.payload["activation_id"], .string("act-1"))
    }

    func testLifecycleHelpersAttachScreenAppAndActionBreadcrumbsToException() async throws {
        let transport = RecordingTransport()
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios", captureActions: true),
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
        client.recordScreen("Checkout", source: "swiftui")
        client.recordAppForeground()
        client.recordAction("tap", targetType: "button", resourceName: "pay_now")
        client.captureException(NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "boom"]))
        await client.flush()

        let batches = await transport.recordedBatches()
        let event = try XCTUnwrap(batches.first?.first)
        let breadcrumbs = try XCTUnwrap(event.payload["breadcrumbs"]?.arrayValue)
        XCTAssertEqual(breadcrumbs.count, 3)
        XCTAssertEqual(breadcrumbs[0].objectValue?["breadcrumb_type"], .string("screen_transition"))
        XCTAssertEqual(breadcrumbs[1].objectValue?["breadcrumb_type"], .string("app_foreground"))
        XCTAssertEqual(breadcrumbs[2].objectValue?["breadcrumb_type"], .string("user_action"))
        XCTAssertEqual(breadcrumbs[2].objectValue?["data"]?.objectValue?["target_type"], .string("button"))
    }

    func testSwiftLogHandlerCapturesStructuredLogEvent() async throws {
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

        var logger = Logger(label: "checkout") { label in
            DebugBundleLogHandler(label: label) { level, message, context in
                client.captureLog(message, level: level, context: context)
            }
        }
        logger[metadataKey: "request_id"] = "req-123"
        logger.warning("payment failed", metadata: [
            "authorization": "Bearer secret",
            "checkout_step": "review"
        ])

        await client.flush()

        let batches = await transport.recordedBatches()
        let event = try XCTUnwrap(batches.first?.first)
        XCTAssertEqual(event.eventType, DebugBundleEventType.logEvent)
        XCTAssertEqual(event.payload["message"], .string("payment failed"))
        XCTAssertEqual(event.payload["context"]?.objectValue?["logger_label"], .string("checkout"))
        XCTAssertEqual(event.payload["context"]?.objectValue?["request_id"], .string("req-123"))
        XCTAssertEqual(event.payload["context"]?.objectValue?["authorization"], .string("[REDACTED]"))
        XCTAssertEqual(event.payload["context"]?.objectValue?["checkout_step"], .string("review"))
    }

    func testOpportunisticRemoteConfigRefreshUsesBoundedIntervalForFlushAndForeground() async {
        let transport = RecordingTransport()
        let remoteConfigClient = CountingRemoteConfigClient(result: .loaded(
            DebugBundleRemoteConfigResponse(
                pollIntervalMillis: 60_000,
                capturePolicy: DebugBundleRemoteCapturePolicy(
                    preset: "balanced",
                    captureLogs: "warning",
                    captureRequestEvents: "failures_only",
                    captureBreadcrumbs: "exception_only",
                    captureProbeEvents: "buffer_only"
                )
            ),
            eTag: "tag-1"
        ))
        var currentTime = Date(timeIntervalSince1970: 10_000)
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios"),
            transport: transport,
            remoteConfigClient: remoteConfigClient,
            clock: { currentTime },
            random: { 0 }
        )

        let initRefreshCount = await waitForFetchCount(on: remoteConfigClient, minimum: 1)
        XCTAssertEqual(initRefreshCount, 1)

        await client.refreshRemoteConfig()
        let initialFetchCount = await waitForFetchCount(on: remoteConfigClient, minimum: 2)
        XCTAssertEqual(initialFetchCount, 2)

        client.captureMessage("hello", level: .error)
        await client.flush()
        let suppressedFlushFetchCount = await remoteConfigClient.fetchCount()
        XCTAssertEqual(suppressedFlushFetchCount, 2)

        currentTime = currentTime.addingTimeInterval(60)
        await client.flush()
        let secondFetchCount = await remoteConfigClient.fetchCount()
        XCTAssertEqual(secondFetchCount, 3)

        client.recordAppForeground()
        let suppressedForegroundFetchCount = await remoteConfigClient.fetchCount()
        XCTAssertEqual(suppressedForegroundFetchCount, 3)

        currentTime = currentTime.addingTimeInterval(60)
        client.recordAppForeground()
        let thirdFetchCount = await waitForFetchCount(on: remoteConfigClient, minimum: 4)
        XCTAssertEqual(thirdFetchCount, 4)
    }
}

private func waitForFetchCount(on client: CountingRemoteConfigClient, minimum: Int, maxYields: Int = 20) async -> Int {
    for _ in 0 ..< maxYields {
        let count = await client.fetchCount()
        if count >= minimum {
            return count
        }
        await Task.yield()
    }
    return await client.fetchCount()
}

private struct StaticRemoteConfigClient: DebugBundleRemoteConfigClienting {
    let result: DebugBundleRemoteConfigResult

    func fetch(request: DebugBundleRemoteConfigRequest) async -> DebugBundleRemoteConfigResult {
        result
    }
}

private actor CountingRemoteConfigClient: DebugBundleRemoteConfigClienting {
    private let result: DebugBundleRemoteConfigResult
    private var count = 0

    init(result: DebugBundleRemoteConfigResult) {
        self.result = result
    }

    func fetch(request: DebugBundleRemoteConfigRequest) async -> DebugBundleRemoteConfigResult {
        count += 1
        return result
    }

    func fetchCount() -> Int {
        count
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self {
            return value
        }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self {
            return value
        }
        return nil
    }
}