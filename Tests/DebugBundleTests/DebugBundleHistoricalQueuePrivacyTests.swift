import Foundation
import XCTest
@testable import DebugBundle
import DebugBundleTestSupport

final class DebugBundleHistoricalQueuePrivacyTests: XCTestCase {
    func testStartupRewritesPreUpgradeQueueBeforeDelivery() async throws {
        let queueURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("historical-queue.json")
        let store = DebugBundleFileQueueStore(fileURL: queueURL)
        store.persist([DebugBundleEventEnvelope(
            sdkName: "@debugbundle/sdk-swift",
            sdkVersion: "1.0.0",
            service: "checkout-ios",
            environment: "production",
            eventType: DebugBundleEventType.logEvent,
            occurredAt: ISO8601DateFormatter().string(from: Date()),
            correlation: nil,
            payload: [
                "level": .string("error"),
                "message": .string("Failure token=old-queue-secret"),
                "attributes": .object(["apiKey": .string("old-key")])
            ],
            device: DebugBundleDeviceContext(),
            releaseChannel: "unknown",
            appVersion: nil,
            buildNumber: nil
        )])
        XCTAssertTrue(try String(contentsOf: queueURL, encoding: .utf8).contains("old-queue-secret"))
        let transport = RecordingTransport()
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios", offlineQueueURL: queueURL),
            transport: transport,
            connectivityMonitor: nil,
            random: { 0 }
        )
        await client.waitForPendingCapture()
        let rewritten = try String(contentsOf: queueURL, encoding: .utf8)
        XCTAssertFalse(rewritten.contains("old-queue-secret"))
        XCTAssertFalse(rewritten.contains("old-key"))
        await client.flush()
        let events = await transport.recordedBatches().flatMap { $0 }
        XCTAssertEqual(events.first?.payload["message"], .string("Failure token=[REDACTED]"))
    }

    func testCorruptHistoricalQueueIsWithheldAndReplacedWithoutSending() async throws {
        let queueURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("corrupt-queue.json")
        try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("token=old-queue-secret".utf8).write(to: queueURL)
        let transport = RecordingTransport()
        let client = DebugBundleClient(
            config: DebugBundleConfig(projectToken: "token", service: "checkout-ios", offlineQueueURL: queueURL),
            transport: transport,
            connectivityMonitor: nil,
            random: { 0 }
        )
        await client.waitForPendingCapture()
        XCTAssertEqual(try String(contentsOf: queueURL, encoding: .utf8), "[]")
        await client.flush()
        let batches = await transport.recordedBatches()
        XCTAssertTrue(batches.flatMap { $0 }.isEmpty)
    }

}
