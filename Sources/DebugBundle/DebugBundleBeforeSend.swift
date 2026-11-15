import Foundation

func applyDebugBundleBeforeSend(_ event: DebugBundleEventEnvelope, hook: DebugBundleBeforeSend?) -> DebugBundleEventEnvelope? {
    guard let hook else { return event }
    guard let result = hook(event) else { return nil }
    do {
        let fitted = try DebugBundleEvidenceWire.fitHookEvidence(result)
        return try DebugBundleEvidenceWire.accepts(debugBundleAuthoredWire(fitted)) ? fitted : event
    }
    catch DebugBundleEvidenceValidationError.unavailable { return nil }
    catch { return event }
}

func isValidBeforeSendEvent(_ event: DebugBundleEventEnvelope) -> Bool {
    (try? DebugBundleEvidenceWire.accepts(debugBundleAuthoredWire(event))) ?? false
}
