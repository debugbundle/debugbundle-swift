import Foundation
import XCTest
import DebugBundleCrashReporter
import DebugBundleTestSupport
@testable import DebugBundle

final class DebugBundleObjCExceptionSafetyTests: XCTestCase {
    func testCurrentNativeExceptionUsesSuppliedFramesAndNormalWorkerHook() async throws {
        let transport = RecordingTransport(), counter = NativeAdapterCounter()
        let client = makeIsolatedClient(config: DebugBundleConfig(projectToken: "fictional", service: "ios", flushInterval: 60,
            beforeSend: { event in counter.increment(); return event }).withEvidenceOptions(.init(evidenceCapabilities: .init(features: ["exception_evidence_v1"]))),
            transport: transport, random: { 0 })
        client.recordBreadcrumb(breadcrumbType: "current_launch")
        do {
            _ = try DebugBundleCrashReporter.captureNSException(context: ["operation": "native"], client: client, operation: {
                NSException(name: .init("FictionalNativeException"), reason: "fictional native failure", userInfo: nil).raise()
                return 1
            })
            XCTFail("Expected bridged native exception")
        } catch let error as DebugBundleObjCExceptionError {
            XCTAssertEqual(error.name, "FictionalNativeException")
            XCTAssertEqual(error.reason, "fictional native failure")
            XCTAssertFalse(error.stackTrace.isEmpty)
        }
        await client.flush()
        let events = await transport.recordedBatches().flatMap { $0 }
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(event.payload["message"], .string("fictional native failure"))
        XCTAssertEqual(event.payload["exception_evidence"]?.objectValue?["nodes"]?.arrayValue?.first?.objectValue?["trace_origin"], .string("runtime_reported"))
        XCTAssertFalse(event.payload["breadcrumbs"]?.arrayValue?.isEmpty ?? true)
    }

    func testDisabledAndUnconfiguredClientsNeverInvokeProbeProducer() {
        for config in [DebugBundleConfig(projectToken: "fictional", enabled: false), DebugBundleConfig(projectToken: "")] {
            let counter = NativeAdapterCounter()
            let client = makeIsolatedClient(config: config, transport: RecordingTransport(), random: { 0 })
            client.probe("disabled.checkpoint") { counter.increment(); return 1 }
            XCTAssertEqual(counter.value, 0)
        }
    }

    func testProbeFlushOptOutDoesNotAttachBufferedDataToExceptions() async throws {
        let transport = RecordingTransport()
        let client = makeIsolatedClient(config: .init(projectToken: "fictional", service: "ios", probeFlushOnError: false), transport: transport, random: { 0 })
        client.probe("kept.checkpoint", data: ["value": 1])
        client.captureException(NSError(domain: "fictional", code: 1))
        await client.flush()
        let events = await transport.recordedBatches().flatMap { $0 }
        XCTAssertNil(events.first?.payload["probe_data"])
    }

    func testCustomNativeExceptionSnapshotDoesNotInvokeOverridableAccessors() throws {
        let error = UnsafeNativeException(name: .init("FictionalException"), reason: "fictional", userInfo: nil)
        error.calls = 0
        do {
            _ = try DebugBundleCrashReporter.captureNSException(report: { _, _ in }, operation: {
                error.raise()
                return 1
            })
            XCTFail("Expected bridged native exception")
        } catch let wrapped as DebugBundleObjCExceptionError {
            XCTAssertEqual(wrapped.reason, "NSException details unavailable")
        }
        XCTAssertEqual(error.calls, 0)
    }
}

private final class UnsafeNativeException: NSException, @unchecked Sendable {
    var calls = 0
    override var name: NSExceptionName { calls += 1; return .init("UnsafeNativeException") }
    override var reason: String? { calls += 1; return "unsafe reason" }
    override var callStackSymbols: [String] { calls += 1; return ["unsafe frame"] }
}

private final class NativeAdapterCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
