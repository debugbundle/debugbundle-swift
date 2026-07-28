import DebugBundle
import Foundation

public struct DebugBundleCapturedBatch: Decodable, Sendable, Equatable {
    public var batch: [DebugBundleEventEnvelope]

    public init(batch: [DebugBundleEventEnvelope]) {
        self.batch = batch
    }

    public func firstEvent(ofType eventType: String) -> DebugBundleEventEnvelope? {
        batch.first(where: { $0.eventType == eventType })
    }

    private enum CodingKeys: String, CodingKey {
        case events
        case batch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        batch = try container.decodeIfPresent([DebugBundleEventEnvelope].self, forKey: .events)
            ?? container.decode([DebugBundleEventEnvelope].self, forKey: .batch)
    }
}

public extension DebugBundleMockIngestionServer.CapturedRequest {
    func decodeBatch() throws -> DebugBundleCapturedBatch {
        try JSONDecoder().decode(DebugBundleCapturedBatch.self, from: body)
    }
}
