import XCTest
@testable import DebugBundle
import DebugBundleCrashReporter
import DebugBundleTestSupport
import Foundation

final class DebugBundleCrashReporterTests: XCTestCase {
    func testEvidenceStoreAndSynchronousCaptureFailClosedAndPreserveResults() throws {
        struct SampleError: LocalizedError {
            var errorDescription: String? { "sync failed" }
        }

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("fatal-crash.json")
        let store = DebugBundleCrashEvidenceStore(fileURL: tempFile)
        XCTAssertFalse(DebugBundleCrashReporter.replayPendingCrash(store: store, report: { _, _ in }))

        let evidence = DebugBundleCrashEvidence(
            errorType: "SampleError",
            message: "first",
            occurredAt: "2026-05-29T10:00:00Z",
            stackTrace: (0 ..< 40).map { "Frame\($0)" }
        )
        XCTAssertEqual(evidence.threadName, "main")
        XCTAssertEqual(evidence.stackTrace.count, 32)
        store.persist(evidence)

        var replacement = evidence
        replacement.message = "replacement"
        store.persist(replacement)
        XCTAssertEqual(store.load()?.message, "replacement")
        store.clear()
        store.clear()
        XCTAssertNil(store.load())

        let successfulValue = try DebugBundleCrashReporter.capture(operation: { 42 })
        XCTAssertEqual(successfulValue, 42)

        var reportedContext: [String: Any?] = [:]
        XCTAssertThrowsError(
            try DebugBundleCrashReporter.capture(
                context: ["operation": "sync"],
                report: { _, context in reportedContext = context },
                operation: { throw SampleError() }
            )
        )
        XCTAssertEqual(reportedContext["operation"] as? String, "sync")

        let exceptionValue = try DebugBundleCrashReporter.captureNSException(operation: { 43 })
        XCTAssertEqual(exceptionValue, 43)
    }

    func testReplayPendingCrashCapturesExceptionAndClearsStore() async throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("fatal-crash.json")
        let store = DebugBundleCrashEvidenceStore(fileURL: tempFile)
        let transport = RecordingTransport()
        let client = makeIsolatedClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios"),
            transport: transport,
            random: { 0 }
        )

        DebugBundleCrashReporter.persistFatalCrash(
            NSError(domain: "Test", code: 99, userInfo: [NSLocalizedDescriptionKey: "fatal boom"]),
            mechanism: "next_launch_replay",
            store: store,
            occurredAt: Date(timeIntervalSince1970: 6_000),
            threadName: "main",
            stackTrace: ["FrameA", "FrameB"]
        )

        let replayed = DebugBundleCrashReporter.replayPendingCrash(store: store) { error, context in
            client.captureError(error, context: context)
        }
        await client.flush()

        XCTAssertTrue(replayed)
        XCTAssertNil(store.load())

        let batches = await transport.recordedBatches()
        let event = try XCTUnwrap(batches.first?.first)
        XCTAssertEqual(event.eventType, DebugBundleEventType.frontendException)
        XCTAssertEqual(event.payload["message"], .string("fatal boom"))
        XCTAssertEqual(event.context?["fatal_crash"], .bool(true))
        XCTAssertEqual(event.context?["crash_replayed"], .bool(true))
        XCTAssertEqual(event.context?["mechanism"], .string("next_launch_replay"))
        XCTAssertEqual(event.context?["thread_name"], .string("main"))
        XCTAssertEqual(event.context?["stack_trace"]?.arrayValue?.count, 2)
    }

    func testCaptureAsyncReportsAndRethrows() async throws {
        struct SampleError: LocalizedError {
            var errorDescription: String? { "async failed" }
        }

        let transport = RecordingTransport()
        let client = makeIsolatedClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios"),
            transport: transport,
            random: { 0 }
        )

        do {
            _ = try await DebugBundleCrashReporter.captureAsync(
                context: ["operation": "payment_refresh"],
                report: { error, context in
                    client.captureError(error, context: context)
                },
                operation: {
                    throw SampleError()
                }
            )
            XCTFail("expected error")
        } catch {
            XCTAssertEqual((error as NSError).localizedDescription, "async failed")
        }

        await client.flush()

        let batches = await transport.recordedBatches()
        let event = try XCTUnwrap(batches.first?.first)
        XCTAssertEqual(event.eventType, DebugBundleEventType.frontendException)
        XCTAssertEqual(event.context?["operation"], .string("payment_refresh"))
        XCTAssertEqual(event.payload["message"], .string("Error details unavailable (custom value type)"))
    }

    func testCaptureAsyncReturnsSuccessfulValue() async throws {
        let value = try await DebugBundleCrashReporter.captureAsync(operation: { 44 })
        XCTAssertEqual(value, 44)
    }

    func testCaptureNSExceptionReportsAndThrowsBridgedError() async throws {
        let transport = RecordingTransport()
        let client = makeIsolatedClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios"),
            transport: transport,
            random: { 0 }
        )

        do {
            _ = try DebugBundleCrashReporter.captureNSException(
                context: ["operation": "objc_bridge"],
                report: { error, context in
                    client.captureError(error, context: context)
                },
                operation: {
                    NSException(name: NSExceptionName("DBTestException"), reason: "objc failed", userInfo: nil).raise()
                    return 123
                }
            )
            XCTFail("expected Objective-C exception bridge to throw")
        } catch let error as DebugBundleObjCExceptionError {
            XCTAssertEqual(error.name, "DBTestException")
            XCTAssertEqual(error.reason, "objc failed")
        }

        await client.flush()

        let batches = await transport.recordedBatches()
        let event = try XCTUnwrap(batches.first?.first)
        XCTAssertEqual(event.eventType, DebugBundleEventType.frontendException)
        XCTAssertEqual(event.context?["operation"], .string("objc_bridge"))
        XCTAssertEqual(event.context?["ns_exception_name"], .string("DBTestException"))
        XCTAssertEqual(event.context?["mechanism"], .string("ns_exception"))
        XCTAssertEqual(event.payload["message"], .string("objc failed"))
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
