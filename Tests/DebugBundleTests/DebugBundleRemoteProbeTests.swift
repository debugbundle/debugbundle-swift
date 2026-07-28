import CryptoKit
import Foundation
import XCTest
@testable import DebugBundle

final class DebugBundleRemoteProbeTests: XCTestCase {
    func testRemoteProbeStateFiltersActivationScopeExpiryAndPiggybackUpdates() {
        let now = Date(timeIntervalSince1970: 1_000)
        let future = ISO8601DateFormatter().string(from: now.addingTimeInterval(60))
        let past = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let matching = DebugBundleRemoteProbeDirective(
            activationId: "",
            id: "fallback-id",
            labelPattern: "checkout.*",
            service: "checkout-ios",
            environment: "production",
            expiresAt: future
        )
        let expired = DebugBundleRemoteProbeDirective(
            activationId: "expired",
            labelPattern: "*",
            service: "*",
            environment: "*",
            expiresAt: past
        )
        XCTAssertEqual(matching.effectiveActivationId, "fallback-id")
        XCTAssertEqual(
            DebugBundleRemoteProbeDirective(
                activationId: "activation",
                labelPattern: "*",
                service: "*",
                environment: "*",
                expiresAt: future
            ).effectiveActivationId,
            "activation"
        )

        let state = DebugBundleRemoteProbeState()
        XCTAssertTrue(state.probesAreEnabled())
        XCTAssertNil(state.tokenKey())
        state.applyConfig(
            probesEnabled: true,
            remoteProbesEnabled: true,
            directives: [matching, expired],
            triggerTokenKey: "key",
            now: now
        )
        XCTAssertEqual(state.tokenKey(), "key")
        XCTAssertEqual(
            state.matchingDirectives(
                label: "checkout.total",
                service: "checkout-ios",
                environment: "production",
                now: now
            ).map(\.effectiveActivationId),
            ["fallback-id"]
        )
        XCTAssertTrue(
            state.matchingDirectives(
                label: "other",
                service: "checkout-ios",
                environment: "production",
                now: now
            ).isEmpty
        )
        XCTAssertTrue(
            state.matchingDirectives(
                label: "checkout.total",
                service: "other",
                environment: "production",
                now: now
            ).isEmpty
        )

        let wildcard = DebugBundleRemoteProbeDirective(
            activationId: "wildcard",
            labelPattern: "*",
            service: "*",
            environment: "*",
            expiresAt: future
        )
        state.activateTrigger(wildcard)
        XCTAssertEqual(
            state.matchingDirectives(
                label: "anything",
                service: "any-service",
                environment: "any-environment",
                now: now
            ).map(\.effectiveActivationId),
            ["wildcard"]
        )
        state.applyPiggybackDirectives(nil, now: now)
        state.applyPiggybackDirectives([matching], now: now)
        state.applyConfig(
            probesEnabled: false,
            remoteProbesEnabled: false,
            directives: [matching],
            triggerTokenKey: nil,
            now: now
        )
        XCTAssertFalse(state.probesAreEnabled())
        XCTAssertTrue(
            state.matchingDirectives(
                label: "checkout.total",
                service: "checkout-ios",
                environment: "production",
                now: now
            ).isEmpty
        )
        state.applyPiggybackDirectives([matching], now: now)
    }

    func testTriggerTokenValidationAcceptsOnlySignedActivePayloads() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let expiry = ISO8601DateFormatter().string(from: now.addingTimeInterval(60))
        let key = "trigger-key"
        let payload = DebugBundleProbeTriggerPayload(
            activationId: "activation",
            labelPattern: "checkout.*",
            service: "checkout-ios",
            environment: "production",
            triggerExpiresAt: expiry
        )
        let payloadSegment = try JSONEncoder().encode(payload).base64URLString()
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(payloadSegment.utf8),
            using: SymmetricKey(data: Data(key.utf8))
        )
        let signatureSegment = Data(signature).base64URLString()
        let token = "dbundle_probe_\(payloadSegment).\(signatureSegment)"

        XCTAssertEqual(
            DebugBundleProbeTriggerTokenValidator.validate(token: token, triggerTokenKey: key, now: now)?.activationId,
            "activation"
        )
        XCTAssertNil(DebugBundleProbeTriggerTokenValidator.validate(token: token, triggerTokenKey: nil, now: now))
        XCTAssertNil(DebugBundleProbeTriggerTokenValidator.validate(token: token, triggerTokenKey: "", now: now))
        XCTAssertNil(DebugBundleProbeTriggerTokenValidator.validate(token: "invalid", triggerTokenKey: key, now: now))
        XCTAssertNil(
            DebugBundleProbeTriggerTokenValidator.validate(
                token: "dbundle_probe_missing-separator",
                triggerTokenKey: key,
                now: now
            )
        )
        XCTAssertNil(
            DebugBundleProbeTriggerTokenValidator.validate(
                token: "dbundle_probe_\(payloadSegment).a",
                triggerTokenKey: key,
                now: now
            )
        )
        XCTAssertNil(
            DebugBundleProbeTriggerTokenValidator.validate(
                token: "dbundle_probe_invalid.\(signatureSegment)",
                triggerTokenKey: key,
                now: now
            )
        )
        XCTAssertNil(
            DebugBundleProbeTriggerTokenValidator.validate(
                token: token,
                triggerTokenKey: key,
                now: now.addingTimeInterval(120)
            )
        )
    }
}

private extension Data {
    func base64URLString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
