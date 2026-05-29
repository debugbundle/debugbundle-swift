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
}

public extension DebugBundleMockIngestionServer.CapturedRequest {
    func decodeBatch() throws -> DebugBundleCapturedBatch {
        try JSONDecoder().decode(DebugBundleCapturedBatch.self, from: body)
    }
}