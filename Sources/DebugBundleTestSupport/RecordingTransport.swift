import DebugBundle
import Foundation

public actor RecordingTransport: DebugBundleTransporting {
    public private(set) var batches: [[DebugBundleEventEnvelope]] = []
    public var nextResult: DebugBundleTransportResult = DebugBundleTransportResult(statusCode: 202)
    public var nextError: Error?

    public init() {}

    public func send(events: [DebugBundleEventEnvelope], config: DebugBundleConfig) async throws -> DebugBundleTransportResult {
        if let nextError {
            throw nextError
        }
        batches.append(events)
        return nextResult
    }

    public func recordedBatches() -> [[DebugBundleEventEnvelope]] {
        batches
    }
}

public enum DebugBundleQueueInspector {
    public static func loadEvents(from fileURL: URL) throws -> [DebugBundleEventEnvelope] {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([DebugBundleEventEnvelope].self, from: data)
    }
}