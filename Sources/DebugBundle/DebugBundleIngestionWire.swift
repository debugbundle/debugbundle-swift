import Foundation

/// Measure the native serializer including wrapper/commas, independently of receiving evidence limits.
enum DebugBundleIngestionWire {
    static let maximumBytes = 262_144
    private static func size(_ event: DebugBundleEventEnvelope) -> Int { (try? JSONEncoder().encode(event).count) ?? Int.max }
    static func fit(_ original: DebugBundleEventEnvelope) -> DebugBundleEventEnvelope? {
        if size(original) <= maximumBytes - 13 { return original }
        guard debugBundleIsException(original.eventType) else { return nil }
        let reduced = withoutEvidence(original)
        return isValidBeforeSendEvent(reduced) && size(reduced) <= maximumBytes - 13 ? reduced : nil
    }
    static func withoutEvidence(_ original: DebugBundleEventEnvelope) -> DebugBundleEventEnvelope {
        var reduced = original
        for key in ["exception_evidence", "execution", "resource_observations"] { reduced.payload.removeValue(forKey: key) }
        if DebugBundleEvidenceWire.reference(reduced.context?["evidence_reference"]) { reduced.context?.removeValue(forKey: "evidence_reference") }
        return reduced
    }
    static func prefixCount(_ events: [DebugBundleEventEnvelope]) -> Int {
        var bytes = 13, count = 0
        for event in events.prefix(100) {
            let next = size(event)
            let separator = count == 0 ? 0 : 1
            guard next <= maximumBytes - bytes - separator else { break }
            bytes += next + separator; count += 1
        }
        return count
    }
}
