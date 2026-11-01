import Foundation

func applyDebugBundleBeforeSend(_ event: DebugBundleEventEnvelope, hook: DebugBundleBeforeSend?) -> DebugBundleEventEnvelope? {
    guard let hook else { return event }
    guard let result = hook(event) else { return nil }
    do { return try DebugBundleEvidenceWire.accepts(debugBundleAuthoredWire(result)) ? result : event }
    catch DebugBundleEvidenceValidationError.unavailable { return nil }
    catch { return event }
}

func isValidBeforeSendEvent(_ event: DebugBundleEventEnvelope) -> Bool {
    (try? DebugBundleEvidenceWire.accepts(debugBundleAuthoredWire(event))) ?? false
}
