import XCTest
@testable import DebugBundle
import DebugBundleCrashReporter
import DebugBundleTestSupport
import Foundation

final class DebugBundleCrashReporterTests: XCTestCase {
    func testReplayPendingCrashCapturesExceptionAndClearsStore() async throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("fatal-crash.json")
        let store = DebugBundleCrashEvidenceStore(fileURL: tempFile)
        let transport = RecordingTransport()
        let client = DebugBundleClient(
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
        XCTAssertEqual(event.payload["context"]?.objectValue?["fatal_crash"], .bool(true))
        XCTAssertEqual(event.payload["context"]?.objectValue?["crash_replayed"], .bool(true))
        XCTAssertEqual(event.payload["context"]?.objectValue?["mechanism"], .string("next_launch_replay"))
        XCTAssertEqual(event.payload["context"]?.objectValue?["thread_name"], .string("main"))
        XCTAssertEqual(event.payload["context"]?.objectValue?["stack_trace"]?.arrayValue?.count, 2)
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
        XCTAssertEqual(event.payload["context"]?.objectValue?["operation"], .string("payment_refresh"))
        XCTAssertEqual(event.payload["error"]?.objectValue?["message"], .string("async failed"))
    }

    func testCaptureNSExceptionReportsAndThrowsBridgedError() async throws {
        let transport = RecordingTransport()
        let client = DebugBundleClient(
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
        XCTAssertEqual(event.payload["context"]?.objectValue?["operation"], .string("objc_bridge"))
        XCTAssertEqual(event.payload["context"]?.objectValue?["ns_exception_name"], .string("DBTestException"))
        XCTAssertEqual(event.payload["context"]?.objectValue?["mechanism"], .string("ns_exception"))
        XCTAssertEqual(event.payload["error"]?.objectValue?["message"], .string("objc failed"))
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