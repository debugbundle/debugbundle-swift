import Foundation
import XCTest
import DebugBundleTestSupport
@testable import DebugBundle

final class DebugBundleBridgeEvidenceTests: XCTestCase {
    private func authored() throws -> [String: Any?] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "evidence-wire-cases", withExtension: "json"))
        let corpus = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let raw = try XCTUnwrap(corpus.objectValue?["events"]?.arrayValue?.first?.objectValue?["event"])
        var event = try JSONDecoder().decode(DebugBundleEventEnvelope.self, from: JSONEncoder().encode(raw))
        let graph = event.payload["exception_evidence"]
        event.sdkName = "@debugbundle/sdk-react-native"
        event.occurredAt = debugBundleTimestamp(Date())
        event.payload = canonicalizeSwiftEvent(eventType: event.eventType, payload: event.payload, device: event.device, occurredAt: event.occurredAt).payload
        event.payload["exception_evidence"] = graph
        event.correlation = .init(requestId: "request", traceId: "trace", sessionId: "0", userIdHash: "opaque-user-hash")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any?])
    }
    private func client(_ transport: RecordingTransport, policy: DebugBundleRemoteConfigClienting = BridgeEvidencePolicy()) -> DebugBundleClient {
        makeIsolatedClient(config: DebugBundleConfig(projectToken: "fictional", service: "native", flushInterval: 60)
            .withEvidenceOptions(.init(captureRecoveryObservations: true, evidenceCapabilities: .init(features: DebugBundleEvidenceCapabilities.known))),
            transport: transport, remoteConfigClient: policy, random: { 0 })
    }
    func testNativeCapabilityGetterIntersectsLocalOptionsAndDiagnosticPolicy() async {
        let policy = BridgeSwitchableEvidencePolicy()
        let client = client(RecordingTransport(), policy: policy)
        XCTAssertTrue(client.evidenceCapabilities.features.contains("exception_evidence_v1"))
        XCTAssertFalse(client.evidenceCapabilities.features.contains("recovery_v1"))
        await policy.enable()
        await client.refreshRemoteConfig()
        XCTAssertEqual(client.evidenceCapabilities.features, DebugBundleEvidenceCapabilities.known)
        let disabled = makeIsolatedClient(config: DebugBundleConfig(projectToken: "fictional")
            .withEvidenceOptions(.init(captureExceptionEvidence: false, evidenceCapabilities: .init(features: DebugBundleEvidenceCapabilities.known))), transport: RecordingTransport())
        XCTAssertFalse(disabled.evidenceCapabilities.features.contains("exception_evidence_v1"))
        XCTAssertFalse(disabled.evidenceCapabilities.features.contains("recovery_v1"))
    }

    func testPlainNativeJsonOwnershipHandlesPrimitivesAndRejectsBudgetsCyclesAndForeignSequences() throws {
        let primitive: [String: Any?] = ["nil": nil, "null": NSNull(), "bool": true, "int": Int(1), "int8": Int8(2), "int16": Int16(3),
            "int32": Int32(4), "int64": Int64(5), "uint": UInt(6), "uint8": UInt8(7), "uint16": UInt16(8), "uint32": UInt32(9),
            "uint64": UInt64(10), "double": Double(1.5), "float": Float(2.5), "json": JSONValue.object(["array": .array([.string("value"), .null, .bool(false), .number(1)])])]
        let copied = try XCTUnwrap(DebugBundleBridgeJSON.object(primitive))
        XCTAssertEqual(copied["nil"], .null)
        XCTAssertEqual(copied["int64"], .number(5))
        XCTAssertEqual(copied["float"], .number(2.5))
        XCTAssertEqual(DebugBundleBridgeJSON.object(["empty": [:] as [AnyHashable: Any]])?["empty"], .object([:]))
        XCTAssertEqual(DebugBundleBridgeJSON.object(["object": [AnyHashable("key"): "value"]])?["object"], .object(["key": .string("value")]))
        XCTAssertNil(DebugBundleBridgeJSON.object(["object": [AnyHashable(1): "value"]]))
        let mutable = NSMutableString(string: "original")
        let array = NSMutableArray(array: [mutable, NSNumber(value: true), NSNull()])
        let dictionary = NSMutableDictionary(dictionary: ["values": array])
        let native = try XCTUnwrap(DebugBundleBridgeJSON.object(["native": dictionary]))
        mutable.setString("changed")
        XCTAssertEqual(native["native"]?.objectValue?["values"]?.arrayValue?.first, .string("original"))
        let invalidKeys = NSMutableDictionary(); invalidKeys[NSNumber(value: 1)] = "invalid"
        XCTAssertTrue(DebugBundleBridgeJSON.object(["native": invalidKeys]) == nil)
        XCTAssertTrue(DebugBundleBridgeJSON.object(["large": NSString(string: String(repeating: "x", count: 300_000))]) == nil)
        XCTAssertTrue(DebugBundleBridgeJSON.object(["large": String(repeating: "/", count: 140_000)]) == nil)
        XCTAssertTrue(DebugBundleBridgeJSON.object(["number": Double.nan]) == nil)
        XCTAssertTrue(DebugBundleBridgeJSON.object(["number": NSNumber(value: Double.infinity)]) == nil)
        XCTAssertTrue(DebugBundleBridgeJSON.object(["date": Date()]) == nil)
        XCTAssertTrue(DebugBundleBridgeJSON.object(["array": Array(repeating: 1, count: 257)]) == nil)
        XCTAssertTrue(DebugBundleBridgeJSON.object(Dictionary(uniqueKeysWithValues: (0..<257).map { ("key-\($0)", 1 as Any?) })) == nil)
        var deep = JSONValue.null
        for _ in 0..<18 { deep = .array([deep]) }
        XCTAssertTrue(DebugBundleBridgeJSON.object(["deep": deep]) == nil)
        let cyclic = NSMutableArray(); cyclic.add(cyclic)
        defer { cyclic.removeAllObjects() }
        XCTAssertTrue(DebugBundleBridgeJSON.object(["cycle": cyclic]) == nil)
        let counter = BridgeIteratorCounter()
        let foreign = AnySequence<Int> { counter.value += 1; return AnyIterator<Int> { nil } }
        XCTAssertTrue(DebugBundleBridgeJSON.object(["foreign": foreign]) == nil)
        XCTAssertEqual(counter.value, 0)
    }

    func testNativeBridgePreservesGraphDepthAndCompleteCorrelation() async throws {
        let raw = try authored(), transport = RecordingTransport()
        let client = client(transport)
        await client.refreshRemoteConfig()
        XCTAssertTrue(client.captureExternalEvent(raw))
        await client.flush()
        let events = await transport.recordedBatches().flatMap { $0 }
        let captured = try XCTUnwrap(events.first)
        let graph = try XCTUnwrap((raw["payload"] as? [String: Any?])?["exception_evidence"] ?? nil)
        let expected = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: graph))
        XCTAssertEqual(captured.payload["exception_evidence"], expected)
        XCTAssertEqual(captured.correlation?.requestId, "request")
        XCTAssertEqual(captured.correlation?.sessionId, "0")
        XCTAssertEqual(captured.correlation?.userIdHash, "opaque-user-hash")
        XCTAssertTrue(isValidBeforeSendEvent(captured))
    }
    func testBridgeMissingDeviceUsesNativeWorkerMetadataWithoutLosingAuthoredEvidence() async throws {
        var raw = try authored()
        var payload = try XCTUnwrap(raw["payload"] as? [String: Any?])
        payload.removeValue(forKey: "device")
        raw["payload"] = payload
        let transport = RecordingTransport()
        let client = makeIsolatedClient(config: DebugBundleConfig(projectToken: "fictional", flushInterval: 60)
            .withEvidenceOptions(.init(evidenceCapabilities: .init(features: DebugBundleEvidenceCapabilities.known))),
            transport: transport, random: { 0 }, deviceContextProvider: { .init(model: "native-worker-model") })
        XCTAssertTrue(client.captureExternalEvent(raw))
        await client.flush()
        let events = await transport.recordedBatches().flatMap { $0 }
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.payload["device"]?.objectValue?["model"], .string("native-worker-model"))
        XCTAssertNotNil(event.payload["exception_evidence"])
        XCTAssertEqual(event.correlation?.sessionId, "0")
    }
    func testRecoveryPassesNativeOwnershipAndInvalidNewFieldsNeverBecomeLegacy() async throws {
        var raw = try authored()
        raw["event_type"] = "diagnostic_context"
        raw["payload"] = ["version": 1, "kind": "recovery", "failure_ref": UUID().uuidString.lowercased(),
            "scope": ["kind": "page", "page_id": UUID().uuidString.lowercased()], "attempt_id": UUID().uuidString.lowercased(), "state": "attempt_completed", "status_code": 200] as [String: Any]
        let transport = RecordingTransport(), client = client(transport)
        await client.refreshRemoteConfig()
        XCTAssertTrue(client.captureExternalEvent(raw))
        var invalid = try authored()
        var payload = try XCTUnwrap(invalid["payload"] as? [String: Any?])
        payload["exception_evidence"] = ["version": 99]
        invalid["payload"] = payload
        XCTAssertFalse(client.captureExternalEvent(invalid))
        await client.flush()
        let events = await transport.recordedBatches().flatMap { $0 }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.payload["state"], .string("attempt_completed"))
        XCTAssertEqual(events.first?.correlation?.sessionId, "0")
        let recovery = try XCTUnwrap(events.first)
        XCTAssertNil(recovery.payload["device"])
        XCTAssertTrue(isValidBeforeSendEvent(recovery))
        let wire = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(recovery))
        XCTAssertTrue(try DebugBundleEvidenceWire.accepts(wire))
    }
    func testLegacyNestedErrorAndRootDeviceRemainCompatibleWithCompleteCorrelation() async throws {
        var raw = try authored()
        raw["schema_version"] = "1"
        raw["payload"] = ["error": ["type": "LegacyType", "message": "legacy primary", "stack_trace": ["at Legacy.tsx:7:2"]]]
        raw["device"] = ["model": "retained-model", "screen": ["width": 390, "height": 844]]
        let transport = RecordingTransport(), client = client(transport)
        XCTAssertTrue(client.captureExternalEvent(raw))
        var invalid = raw
        invalid["correlation"] = ["unknown": "rejected"]
        XCTAssertFalse(client.captureExternalEvent(invalid))
        invalid["correlation"] = ["trace_id": 123]
        XCTAssertFalse(client.captureExternalEvent(invalid))
        await client.flush()
        let events = await transport.recordedBatches().flatMap { $0 }
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.payload["name"], .string("LegacyType"))
        XCTAssertEqual(event.payload["stack"], .string("at Legacy.tsx:7:2"))
        XCTAssertEqual(event.device.model, "retained-model")
        XCTAssertEqual(event.device.screenResolution, "390x844")
        XCTAssertEqual(event.correlation?.requestId, "request")
        XCTAssertEqual(event.correlation?.userIdHash, "opaque-user-hash")
    }
    func testCanonicalAllowedSdkIdentityAndNullableRuntimeSurviveBridge() async throws {
        var raw = try authored()
        raw["sdk_name"] = "@debugbundle/sdk-swift"
        var service = try XCTUnwrap(raw["service"] as? [String: Any?])
        service["runtime"] = NSNull()
        raw["service"] = service
        let transport = RecordingTransport(), client = client(transport)
        await client.refreshRemoteConfig()
        XCTAssertTrue(client.captureExternalEvent(raw))
        await client.flush()
        let events = await transport.recordedBatches().flatMap { $0 }
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.sdkName, "@debugbundle/sdk-swift")
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(event))
        XCTAssertNil(value.objectValue?["service"]?.objectValue?["runtime"]?.stringValue)
    }
    func testForeignBridgeValuesAreWithheldWithoutFormatters() throws {
        let value = BridgeForeignValue()
        var raw = try authored()
        raw["context"] = ["foreign": value]
        XCTAssertFalse(client(RecordingTransport()).captureExternalEvent(raw))
        XCTAssertEqual(value.calls, 0)
    }
}
// Startup refresh can complete before the first assertion. Keep policy unavailable
// until this test explicitly enables it, independent of task scheduling.
private actor BridgeSwitchableEvidencePolicy: DebugBundleRemoteConfigClienting {
    private var enabled = false
    func enable() { enabled = true }
    func fetch(request: DebugBundleRemoteConfigRequest) async -> DebugBundleRemoteConfigResult {
        enabled ? .loaded(.init(capturePolicy: .init(preset: "balanced")), eTag: nil) : .failed
    }
}
private struct BridgeEvidencePolicy: DebugBundleRemoteConfigClienting {
    func fetch(request: DebugBundleRemoteConfigRequest) async -> DebugBundleRemoteConfigResult { .loaded(.init(capturePolicy: .init(preset: "balanced")), eTag: nil) }
}
private final class BridgeForeignValue: CustomStringConvertible {
    var calls = 0
    var description: String { calls += 1; return "unsafe formatter" }
}

private final class BridgeIteratorCounter { var value = 0 }
