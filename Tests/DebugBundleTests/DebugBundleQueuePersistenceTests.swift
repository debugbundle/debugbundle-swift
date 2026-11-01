import Foundation
import XCTest
@testable import DebugBundle

final class DebugBundleQueuePersistenceTests: XCTestCase {
    func testNativeQueueAcknowledgesOnlyCompletedAtomicWritesAndKeepsVoidAPI() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("queue.json")
        let store = DebugBundleFileQueueStore(fileURL: file)
        let event = DebugBundleEventEnvelope(sdkName: "@debugbundle/sdk-swift", sdkVersion: "3.0.1", service: "ios", environment: "test",
            eventType: "log_event", occurredAt: debugBundleTimestamp(Date()), correlation: nil,
            payload: ["level": .string("error"), "message": .string("fictional retained failure"), "attributes": .object([:])],
            device: .init(), releaseChannel: "test", appVersion: nil, buildNumber: nil)
        XCTAssertTrue(store.persistAcknowledging([event]))
        XCTAssertEqual(store.load(now: Date(), ttl: 60).first?.payload["message"], event.payload["message"])
        store.persist([])
        XCTAssertTrue(store.load(now: Date(), ttl: 60).isEmpty)
        let blocked = DebugBundleFileQueueStore(fileURL: file.appendingPathComponent("child.json"))
        XCTAssertFalse(blocked.persistAcknowledging([event]))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "[]")
        XCTAssertTrue((store as DebugBundleQueueStoring) is DebugBundleAcknowledgingQueueStore)
    }
}
