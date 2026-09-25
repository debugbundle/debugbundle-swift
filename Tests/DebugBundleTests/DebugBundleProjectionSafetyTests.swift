import Foundation
import XCTest
@preconcurrency @testable import DebugBundle
import DebugBundleTestSupport
import DebugBundleSwiftLog
import Logging

final class DebugBundleProjectionSafetyTests: XCTestCase {
    func testAcceptedCustomValuesNeverInvokeCallerDescriptionsOrReflection() async {
        let counter = ProjectionCounter()
        let transport = RecordingTransport()
        let client = makeClient(transport: transport)
        client.captureLog("safe", level: .error, context: ["value": ProjectionValue(counter: counter), "bridge": ProjectionBridge(counter: counter)])
        client.captureException(ProjectionValueError(counter: counter))
        XCTAssertEqual(counter.value, 0)
        await client.flush()
        let events = await transport.recordedBatches().flatMap { $0 }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last?.payload["message"], .string("Error details unavailable (custom value type)"))
    }

    func testHeldDeviceProviderDoesNotBlockCapture() async {
        let entered = expectation(description: "device provider entered")
        let release = DispatchSemaphore(value: 0)
        let transport = RecordingTransport()
        let client = makeClient(transport: transport, provider: {
            entered.fulfill(); release.wait(); return DebugBundleDeviceContext(model: "worker-device")
        })
        let returned = expectation(description: "capture returned")
        DispatchQueue.global().async { client.captureLog("safe", level: .error); returned.fulfill() }
        await fulfillment(of: [entered, returned], timeout: 0.25)
        release.signal()
        await client.flush()
        let event = await transport.recordedBatches().flatMap { $0 }.first
        XCTAssertEqual(event?.device.model, "worker-device")
    }

    func testReferenceErrorAccessRunsOnWorkerAndWeakQueueDoesNotExtendLifetime() async {
        let entered = expectation(description: "reference accessor entered")
        let release = DispatchSemaphore(value: 0)
        let transport = RecordingTransport()
        let client = makeClient(transport: transport)
        let error = ProjectionReferenceError(entered: entered, release: release)
        let returned = expectation(description: "reference capture returned")
        DispatchQueue.global().async { client.captureException(error); returned.fulfill() }
        await fulfillment(of: [entered, returned], timeout: 0.25)
        release.signal()
        await client.flush()
        withExtendedLifetime(error) {}
        let events = await transport.recordedBatches().flatMap { $0 }
        XCTAssertEqual(events.first?.payload["message"], .string("reference token=[REDACTED]"))

        let store = HeldProjectionStore()
        let fallbackTransport = RecordingTransport()
        let queuedClient = DebugBundleClient(config: DebugBundleConfig(projectToken: "token", batchSize: 100),
            transport: fallbackTransport, queueStore: store, remoteConfigClient: ProjectionConfig(),
            connectivityMonitor: ProjectionConnectivity(), random: { 0 })
        await fulfillment(of: [store.entered], timeout: 2)
        var temporary: ProjectionReferenceError? = ProjectionReferenceError()
        weak var observed = temporary
        queuedClient.captureException(temporary!)
        temporary = nil
        XCTAssertNil(observed, "The queue must not retain the raw error graph")
        store.release.signal()
        await queuedClient.flush()
        let fallback = await fallbackTransport.recordedBatches().flatMap { $0 }.first
        XCTAssertEqual(fallback?.payload["message"], .string("Error details unavailable (custom reference type)"))
    }

    func testStandardFoundationValuesAndNSErrorMessageRemainBoundedAndSafe() async {
        let transport = RecordingTransport()
        let client = makeClient(transport: transport)
        let counter = ProjectionCounter()
        client.captureLog("values", level: .error, context: [
            "date": Date(timeIntervalSince1970: 0), "url": URL(string: "https://example.test")!,
            "nested": NSMutableDictionary(dictionary: ["route": "/checkout", "password": "private"]),
            "custom": ProjectionObject(counter: counter), "trace_id": ProjectionValue(counter: counter)
        ])
        client.captureException(NSError(domain: "Expected", code: 42, userInfo: [NSLocalizedDescriptionKey: "normal message token=secret"]))
        await client.flush()
        XCTAssertEqual(counter.value, 0)
        let events = await transport.recordedBatches().flatMap { $0 }
        XCTAssertEqual(events.last?.payload["message"], .string("normal message token=[REDACTED]"))
        let attributes = events.first?.payload["attributes"]?.objectValue
        XCTAssertEqual(attributes?["date"], .string("1970-01-01T00:00:00Z"))
        XCTAssertEqual(attributes?["url"], .string("https://example.test"))
        XCTAssertEqual(attributes?["nested"]?.objectValue?["route"], .string("/checkout"))
        XCTAssertEqual(attributes?["nested"]?.objectValue?["password"], .string("[REDACTED]"))
        XCTAssertEqual(attributes?["custom"], .string("[Unsupported value]"))
    }

    func testSwiftLogDoesNotInvokeCustomMetadataOrErrorDescriptions() {
        let counter = ProjectionCounter()
        let handler = DebugBundleLogHandler(label: "safe", metadata: ["value": .stringConvertible(ProjectionValue(counter: counter))], emit: { _, _, _ in })
        handler.log(event: LogEvent(level: .error, message: "safe", error: ProjectionValueError(counter: counter),
            metadata: nil, source: "test", file: "test.swift", function: "test", line: 1))
        XCTAssertEqual(counter.value, 0)
    }

    private func makeClient(transport: DebugBundleTransporting,
        provider: (() -> DebugBundleDeviceContext)? = nil) -> DebugBundleClient {
        DebugBundleClient(config: DebugBundleConfig(projectToken: "token", batchSize: 100, flushInterval: 3600),
            transport: transport, queueStore: ProjectionStore(), remoteConfigClient: ProjectionConfig(),
            connectivityMonitor: ProjectionConnectivity(), random: { 0 }, deviceContextProvider: provider)
    }
}

private final class ProjectionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
private struct ProjectionValue: CustomStringConvertible, CustomReflectable {
    let counter: ProjectionCounter
    var description: String { counter.increment(); return "unsafe description" }
    var customMirror: Mirror { counter.increment(); return Mirror(reflecting: "unsafe mirror") }
}
private struct ProjectionValueError: LocalizedError, CustomNSError {
    let counter: ProjectionCounter
    var errorDescription: String? { counter.increment(); return "unsafe localized value" }
    var errorUserInfo: [String: Any] { counter.increment(); return [NSLocalizedDescriptionKey: "unsafe custom NSError"] }
}
private struct ProjectionStore: DebugBundleQueueStoring {
    func load(now: Date, ttl: TimeInterval) -> [DebugBundleEventEnvelope] { [] }
    func persist(_ events: [DebugBundleEventEnvelope]) {}
}
private struct ProjectionConfig: DebugBundleRemoteConfigClienting {
    func fetch(request: DebugBundleRemoteConfigRequest) async -> DebugBundleRemoteConfigResult { .notModified(eTag: nil) }
}
private final class ProjectionConnectivity: DebugBundleConnectivityMonitoring {
    var currentStatus: DebugBundleConnectivityStatus { .connected }
    func setUpdateHandler(_ handler: (@Sendable (DebugBundleConnectivityStatus) -> Void)?) {}
}

private final class ProjectionObject: NSObject {
    let counter: ProjectionCounter
    init(counter: ProjectionCounter) { self.counter = counter }
    override var description: String { counter.increment(); return "unsafe object" }
}
private final class ProjectionReferenceError: NSError, @unchecked Sendable {
    let entered: XCTestExpectation?
    let release: DispatchSemaphore?
    init(entered: XCTestExpectation? = nil, release: DispatchSemaphore? = nil) {
        self.entered = entered; self.release = release
        super.init(domain: "Reference", code: 1)
    }
    required init?(coder: NSCoder) { nil }
    override var localizedDescription: String {
        entered?.fulfill(); release?.wait(); return "reference token=private-value"
    }
}
private final class HeldProjectionStore: DebugBundleQueueStoring {
    let entered = XCTestExpectation(description: "load entered")
    let release = DispatchSemaphore(value: 0)
    func load(now: Date, ttl: TimeInterval) -> [DebugBundleEventEnvelope] { entered.fulfill(); release.wait(); return [] }
    func persist(_ events: [DebugBundleEventEnvelope]) {}
}

private struct ProjectionBridge: _ObjectiveCBridgeable {
    typealias _ObjectType = NSError
    let counter: ProjectionCounter
    func _bridgeToObjectiveC() -> NSError { counter.increment(); return NSError(domain: "unsafe bridge", code: 1) }
    static func _forceBridgeFromObjectiveC(_ source: NSError, result: inout ProjectionBridge?) { result = nil }
    static func _conditionallyBridgeFromObjectiveC(_ source: NSError, result: inout ProjectionBridge?) -> Bool { false }
    static func _unconditionallyBridgeFromObjectiveC(_ source: NSError?) -> ProjectionBridge { ProjectionBridge(counter: ProjectionCounter()) }
}
