import Foundation

/// Explicit application observations; HTTP success and attempt completion do not imply recovery.
public struct DebugBundleRecoveryObservation: Sendable, Equatable {
    public var failureRef: String
    public var attemptId: String
    public var state: String
    public var scope: DebugBundleEvidenceScope?
    public var operation: String?
    public var statusCode: Int?
    public var durationMs: Double?
    public var traceId: String?
    public var sessionId: String?
    public init(failureRef: String, attemptId: String, state: String, scope: DebugBundleEvidenceScope? = nil,
        operation: String? = nil, statusCode: Int? = nil, durationMs: Double? = nil, traceId: String? = nil, sessionId: String? = nil) {
        self.failureRef = failureRef; self.attemptId = attemptId; self.state = state; self.scope = scope
        self.operation = operation; self.statusCode = statusCode; self.durationMs = durationMs
        self.traceId = traceId; self.sessionId = sessionId
    }
}

extension DebugBundleClient {
    public func captureRecovery(_ observation: DebugBundleRecoveryObservation) {
        let allowed = lock.withLock { capturePolicy.diagnosticsAllowed }
        guard canAdmit(priority: 0), evidence.canCaptureRecovery(allowed), let payload = evidence.recoveryPayload(observation) else { return }
        let event = DebugBundleEventEnvelope(sdkName: "@debugbundle/sdk-swift", sdkVersion: config.sdkVersion,
            service: config.service, environment: config.environment, eventType: "diagnostic_context", occurredAt: debugBundleTimestamp(clock()),
            correlation: .init(requestId: nil, traceId: observation.traceId, sessionId: observation.sessionId, userIdHash: nil), payload: payload,
            device: captureDevicePlaceholder, releaseChannel: config.releaseChannel, appVersion: config.appVersion, buildNumber: config.buildNumber)
        guard let safe = protectDebugBundleEvent(event, redactor: redactor), isValidBeforeSendEvent(safe) else { return }
        _ = capturePreparedEnvelope(safe, needsDeviceContext: false)
    }
}
