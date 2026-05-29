import CryptoKit
import Foundation

public struct DebugBundleRemoteProbeDirective: Codable, Sendable, Equatable {
    public var activationId: String
    public var id: String?
    public var labelPattern: String
    public var service: String
    public var environment: String
    public var expiresAt: String
    public var triggerExpiresAt: String?

    public init(
        activationId: String = "",
        id: String? = nil,
        labelPattern: String,
        service: String,
        environment: String,
        expiresAt: String,
        triggerExpiresAt: String? = nil
    ) {
        self.activationId = activationId
        self.id = id
        self.labelPattern = labelPattern
        self.service = service
        self.environment = environment
        self.expiresAt = expiresAt
        self.triggerExpiresAt = triggerExpiresAt
    }

    public var effectiveActivationId: String {
        if !activationId.isEmpty {
            return activationId
        }
        return id ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case activationId = "activation_id"
        case id
        case labelPattern = "label_pattern"
        case service
        case environment
        case expiresAt = "expires_at"
        case triggerExpiresAt = "trigger_expires_at"
    }
}

struct DebugBundleProbeTriggerPayload: Codable, Sendable, Equatable {
    var activationId: String
    var labelPattern: String
    var service: String
    var environment: String
    var triggerExpiresAt: String

    enum CodingKeys: String, CodingKey {
        case activationId = "activation_id"
        case labelPattern = "label_pattern"
        case service
        case environment
        case triggerExpiresAt = "trigger_expires_at"
    }
}

final class DebugBundleRemoteProbeState {
    private let lock = NSLock()
    private var probesEnabled = true
    private var remoteProbesEnabled = false
    private var remoteProbeDirectives: [DebugBundleRemoteProbeDirective] = []
    private var activeTriggerDirective: DebugBundleRemoteProbeDirective?
    private var triggerTokenKey: String?

    func probesAreEnabled() -> Bool {
        lock.withLock { probesEnabled }
    }

    func tokenKey() -> String? {
        lock.withLock { triggerTokenKey }
    }

    func activateTrigger(_ directive: DebugBundleRemoteProbeDirective) {
        lock.withLock {
            activeTriggerDirective = directive
        }
    }

    func matchingDirectives(label: String, service: String, environment: String, now: Date) -> [DebugBundleRemoteProbeDirective] {
        lock.withLock {
            activeTriggerDirective = activeTriggerDirective?.takeIfActive(at: now)
            guard probesEnabled, remoteProbesEnabled else {
                return []
            }
            remoteProbeDirectives = remoteProbeDirectives.filter { $0.isActive(at: now) }
            let directives = activeTriggerDirective.map { remoteProbeDirectives + [$0] } ?? remoteProbeDirectives
            return directives.filter { $0.matches(label: label, service: service, environment: environment) }
        }
    }

    func applyConfig(
        probesEnabled: Bool,
        remoteProbesEnabled: Bool,
        directives: [DebugBundleRemoteProbeDirective],
        triggerTokenKey: String?,
        now: Date
    ) {
        lock.withLock {
            self.probesEnabled = probesEnabled
            self.remoteProbesEnabled = remoteProbesEnabled
            self.remoteProbeDirectives = remoteProbesEnabled ? directives.filter { $0.isActive(at: now) } : []
            self.triggerTokenKey = triggerTokenKey
            if !probesEnabled || !remoteProbesEnabled {
                activeTriggerDirective = nil
            }
        }
    }

    func applyPiggybackDirectives(_ directives: [DebugBundleRemoteProbeDirective]?, now: Date) {
        guard let directives else {
            return
        }
        lock.withLock {
            guard probesEnabled, remoteProbesEnabled else {
                return
            }
            remoteProbeDirectives = directives.filter { $0.isActive(at: now) }
        }
    }
}

enum DebugBundleProbeTriggerTokenValidator {
    private static let prefix = "dbundle_probe_"
    private static let decoder = JSONDecoder()
    private static let formatter = ISO8601DateFormatter()

    static func validate(token: String, triggerTokenKey: String?, now: Date) -> DebugBundleRemoteProbeDirective? {
        guard let triggerTokenKey, !triggerTokenKey.isEmpty, token.hasPrefix(prefix) else {
            return nil
        }
        let encoded = String(token.dropFirst(prefix.count))
        let parts = encoded.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return nil
        }
        let payloadSegment = parts[0]
        let signatureSegment = parts[1]

        guard hasValidSignature(payloadSegment: payloadSegment, signatureSegment: signatureSegment, triggerTokenKey: triggerTokenKey) else {
            return nil
        }
        guard let payload = decodePayload(payloadSegment) else {
            return nil
        }
        guard let expiry = formatter.date(from: payload.triggerExpiresAt), expiry > now else {
            return nil
        }
        return DebugBundleRemoteProbeDirective(
            activationId: payload.activationId,
            labelPattern: payload.labelPattern,
            service: payload.service,
            environment: payload.environment,
            expiresAt: payload.triggerExpiresAt,
            triggerExpiresAt: payload.triggerExpiresAt
        )
    }

    private static func decodePayload(_ payloadSegment: String) -> DebugBundleProbeTriggerPayload? {
        guard let decodedData = Data(base64URLEncoded: payloadSegment) else {
            return nil
        }
        return try? decoder.decode(DebugBundleProbeTriggerPayload.self, from: decodedData)
    }

    private static func hasValidSignature(payloadSegment: String, signatureSegment: String, triggerTokenKey: String) -> Bool {
        guard let signatureData = Data(base64URLEncoded: signatureSegment) else {
            return false
        }
        let key = SymmetricKey(data: Data(triggerTokenKey.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: Data(payloadSegment.utf8), using: key)
        return constantTimeEqual(Array(signatureData), Array(digest))
    }

    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

private extension DebugBundleRemoteProbeDirective {
    func isActive(at now: Date) -> Bool {
        let formatter = ISO8601DateFormatter()
        guard let expiry = formatter.date(from: expiresAt) else {
            return false
        }
        return expiry > now
    }

    func matches(label: String, service: String, environment: String) -> Bool {
        if self.service != "*" && self.service != service {
            return false
        }
        if self.environment != "*" && self.environment != environment {
            return false
        }
        if labelPattern == "*" {
            return true
        }
        if labelPattern.hasSuffix(".*") {
            return label.hasPrefix(String(labelPattern.dropLast(2)) + ".")
        }
        return label == labelPattern
    }

    func takeIfActive(at now: Date) -> DebugBundleRemoteProbeDirective? {
        isActive(at: now) ? self : nil
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder > 0 {
            padded += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: padded)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}