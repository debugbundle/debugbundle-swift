import Foundation

/// A pin asserts support across every relay and reader in the complete delivery path.
public struct DebugBundleEvidenceCapabilities: Codable, Sendable, Equatable {
    public let version: Int
    public let features: [String]
    static let known = ["exception_evidence_v1", "resource_observations_v1", "recovery_v1", "evidence_provenance_v1"]

    public init(version: Int = 1, features: [String] = []) {
        self.version = 1
        self.features = version == 1 && features.count <= 4 && Set(features).count == features.count
            && features.allSatisfy(Self.known.contains) ? Self.known.filter(features.contains) : []
    }
    public init(from decoder: Decoder) throws {
        self = Self.normalize(try JSONValue(from: decoder))
    }
    public func encode(to encoder: Encoder) throws { try wire.encode(to: encoder) }
    public static func intersect(_ hops: [Self]) -> Self {
        guard !hops.isEmpty, hops.count <= 8 else { return Self() }
        return Self(features: known.filter { feature in hops.allSatisfy { $0.features.contains(feature) } })
    }
    static func normalize(_ raw: JSONValue?) -> Self {
        guard let item = raw?.objectValue, Set(item.keys) == Set(["version", "features"]), item["version"] == .number(1),
              let values = item["features"]?.arrayValue, values.count <= 4 else { return Self() }
        let strings = values.compactMap(\.stringValue)
        guard strings.count == values.count else { return Self() }
        return Self(features: strings)
    }
    var wire: JSONValue { .object(["version": .number(1), "features": .array(features.map(JSONValue.string))]) }
}

public struct DebugBundleEvidenceOptions: Sendable, Equatable {
    public var captureExceptionEvidence: Bool
    public var captureRecoveryObservations: Bool
    public var evidenceCapabilities: DebugBundleEvidenceCapabilities?
    public init(captureExceptionEvidence: Bool = true, captureRecoveryObservations: Bool = false,
        evidenceCapabilities: DebugBundleEvidenceCapabilities? = nil) {
        self.captureExceptionEvidence = captureExceptionEvidence
        self.captureRecoveryObservations = captureRecoveryObservations
        self.evidenceCapabilities = evidenceCapabilities
    }
}

extension DebugBundleConfig {
    /// Existing initializers remain unchanged; configure additive evidence options on a value copy.
    public func withEvidenceOptions(_ options: DebugBundleEvidenceOptions) -> Self {
        var result = self
        result.evidenceOptions = options
        return result
    }
}

/// Shared by preparation and retries; a missing/unknown response revokes discovered support.
final class DebugBundleEvidenceController {
    let operations = DebugBundleOperations()
    let budget = DebugBundleDiagnosticBudget()
    private let options: DebugBundleEvidenceOptions
    private let lock = NSLock()
    private var proof: DebugBundleEvidenceCapabilities
    init(_ options: DebugBundleEvidenceOptions) {
        self.options = options
        self.proof = options.evidenceCapabilities ?? DebugBundleEvidenceCapabilities()
    }
    func observe(_ value: JSONValue?) { lock.withLock { proof = .normalize(value) } }
    func supports(_ feature: String) -> Bool { lock.withLock { proof.features.contains(feature) } }
    var canCaptureExceptions: Bool { options.captureExceptionEvidence && supports("exception_evidence_v1") }
    func capabilities(_ diagnosticsAllowed: Bool) -> DebugBundleEvidenceCapabilities {
        let features = lock.withLock { proof.features }
        return .init(features: features.filter {
            switch $0 {
            case "exception_evidence_v1": return options.captureExceptionEvidence
            case "recovery_v1": return diagnosticsAllowed && options.captureRecoveryObservations
            case "resource_observations_v1": return diagnosticsAllowed
            default: return true
            }
        })
    }
    func canCaptureRecovery(_ allowed: Bool) -> Bool { allowed && options.captureRecoveryObservations && supports("recovery_v1") }
    func canHold(_ event: DebugBundleEventEnvelope) -> Bool {
        event.eventType == "diagnostic_context" && budget.eligible(event)
            && (event.payload["kind"]?.stringValue != "recovery" || options.captureRecoveryObservations)
    }
    func context(_ merged: [String: Any?]) -> [String: Any?] {
        guard supports("recovery_v1") || supports("resource_observations_v1"), let raw = merged["failure_ref"] ?? nil,
              debugBundleIsSafeFoundationValue(raw), let failure = raw as? String, DebugBundleEvidenceWire.freshId(failure) else { return merged }
        let scope: JSONValue?
        if let explicit = merged["evidence_scope"] ?? nil { scope = explicit as? JSONValue }
        else { scope = operations.current()?.wire }
        guard let scope, DebugBundleEvidenceWire.scope(scope) else { return merged }
        var result = merged.filter { !["failure_ref", "evidence_scope"].contains($0.key) }
        result["evidence_reference"] = JSONValue.object(["version": .number(1), "failure_ref": .string(failure), "scope": scope])
        return result
    }
    func recoveryPayload(_ observation: DebugBundleRecoveryObservation) -> [String: JSONValue]? {
        guard let scope = observation.scope?.wire ?? operations.current()?.wire else { return nil }
        var value: [String: JSONValue] = ["version": .number(1), "kind": .string("recovery"), "failure_ref": .string(observation.failureRef),
            "scope": scope, "attempt_id": .string(observation.attemptId), "state": .string(observation.state)]
        if let operation = observation.operation { value["operation"] = .string(operation) }
        if let status = observation.statusCode { value["status_code"] = .number(Double(status)) }
        if let duration = observation.durationMs { value["duration_ms"] = .number(duration) }
        return value
    }
    func reconcile(_ original: DebugBundleEventEnvelope, _ replacement: DebugBundleEventEnvelope?, diagnosticsAllowed: Bool) -> DebugBundleEventEnvelope? {
        let originalId = original.eventType == "diagnostic_context" ? original.eventId : nil
        let filtered = replacement.flatMap { filter($0, diagnosticsAllowed: diagnosticsAllowed, owned: false) }
        if let filtered, filtered.eventType == "diagnostic_context" {
            if !budget.replace(originalId, with: filtered) { budget.release(originalId); return nil }
        } else { budget.release(originalId) }
        return filtered
    }
    func prepared(_ event: DebugBundleEventEnvelope) { if debugBundleIsException(event.eventType) { budget.register(event) } }
    func close() { operations.close(); budget.clear() }
    func filter(_ original: DebugBundleEventEnvelope, diagnosticsAllowed: Bool, owned: Bool = true) -> DebugBundleEventEnvelope? {
        if original.eventType == "diagnostic_context" {
            let kind = original.payload["kind"]?.stringValue
            let enabled = kind == "recovery" ? canCaptureRecovery(diagnosticsAllowed)
                : kind == "resource_observation" && diagnosticsAllowed && supports("resource_observations_v1")
            return enabled && (!owned || budget.eligible(original)) ? original : nil
        }
        var event = original
        if !canCaptureExceptions {
            event.payload.removeValue(forKey: "exception_evidence")
            event.payload.removeValue(forKey: "execution")
        }
        if !diagnosticsAllowed || !supports("resource_observations_v1") { event.payload.removeValue(forKey: "resource_observations") }
        if (!diagnosticsAllowed || !(options.captureRecoveryObservations && supports("recovery_v1")) && !supports("resource_observations_v1")),
           DebugBundleEvidenceWire.reference(event.context?["evidence_reference"]) {
            event.context?.removeValue(forKey: "evidence_reference")
        }
        return event
    }
    static func matchingConfigPath(_ endpoint: URL) -> Bool {
        endpoint.query == nil && endpoint.fragment == nil && endpoint.user == nil && endpoint.password == nil
            && ["http", "https"].contains(endpoint.scheme?.lowercased() ?? "")
            && endpoint.path.hasSuffix("/v1/events")
    }
}
