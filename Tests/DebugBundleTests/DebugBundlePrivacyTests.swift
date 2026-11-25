import CryptoKit
import Foundation
import XCTest
import DebugBundleTestSupport
@testable import DebugBundle

final class DebugBundlePrivacyTests: XCTestCase {
    private struct Fixture: Decodable {
        let policy: String
        let cases: [Case]
        let exactKeyCases: [ExactCase]

        enum CodingKeys: String, CodingKey {
            case policy
            case cases
            case exactKeyCases = "exact_key_cases"
        }

        struct Case: Decodable {
            let id: String
            let input: JSONValue
            let expected: JSONValue
        }

        struct ExactCase: Decodable {
            let id: String
            let additionalKeys: [String]?
            let exactKeys: [String]?
            let input: JSONValue
            let expected: JSONValue

            enum CodingKeys: String, CodingKey {
                case id
                case additionalKeys = "additional_keys"
                case exactKeys = "exact_keys"
                case input
                case expected
            }
        }
    }

    func testNativePolicyMatchesPortablePrivacyAndExactKeyCases() throws {
        let fixturesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures")
        let fixtureData = try Data(contentsOf: fixturesDir.appendingPathComponent("privacy-conformance.json"))
        let expectedHash = try String(contentsOf: fixturesDir.appendingPathComponent("privacy-conformance.sha256"), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).first.map(String.init)
        let actualHash = SHA256.hash(data: fixtureData).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(actualHash, expectedHash)

        let fixture = try JSONDecoder().decode(Fixture.self, from: fixtureData)
        XCTAssertEqual(fixture.policy, "telemetry-privacy-v1")
        XCTAssertEqual(fixture.cases.count, 27)
        XCTAssertEqual(fixture.exactKeyCases.count, 8)

        let redactor = DebugBundleRedactor(sensitiveKeys: [])
        for item in fixture.cases {
            XCTAssertEqual(redactor.sanitizeJSON(item.input), item.expected, item.id)
        }
        for item in fixture.exactKeyCases {
            let exactRedactor = DebugBundleRedactor(
                sensitiveKeys: Set(item.additionalKeys ?? []),
                exactKeys: Set(item.exactKeys ?? [])
            )
            XCTAssertEqual(exactRedactor.sanitizeJSON(item.input), item.expected, item.id)
        }
    }

    func testMandatoryFieldsSurviveCustomConfigurationAndOversizedTextIsWithheld() {
        let redactor = DebugBundleRedactor(sensitiveKeys: ["customer_code"])
        XCTAssertEqual(redactor.sanitizeJSON(.object([
            "password": .string("secret"),
            "customer_code": .string("private"),
            "status": .number(503)
        ])), .object([
            "password": .string("[REDACTED]"),
            "customer_code": .string("[REDACTED]"),
            "status": .number(503)
        ]))
        XCTAssertEqual(redactor.sanitize("x".padding(toLength: 4096, withPad: "x", startingAt: 0) + " password=secret"), .string("[REDACTED]"))
    }

    func testExactKeyEscapesRegexMetacharactersAndEnforcesCombinedCustomKeyBounds() {
        let literalRedactor = DebugBundleRedactor(sensitiveKeys: [], exactKeys: ["foo.bar", "a+b"])
        XCTAssertEqual(
            literalRedactor.sanitizeJSON(.object([
                "foo.bar": .string("SECRET_DOT"),
                "fooXbar": .string("keep-literal"),
                "a+b": .string("SECRET_PLUS"),
                "aab": .string("keep-plus"),
                "message": .string("foo.bar=SECRET_DOT fooXbar=keep a+b=SECRET_PLUS aab=keep")
            ])),
            .object([
                "foo.bar": .string("[REDACTED]"),
                "fooXbar": .string("keep-literal"),
                "a+b": .string("[REDACTED]"),
                "aab": .string("keep-plus"),
                "message": .string("foo.bar=[REDACTED] fooXbar=keep a+b=[REDACTED] aab=keep")
            ])
        )

        // Exact key matching is ASCII case-insensitive with punctuation significant; non-exact siblings survive.
        let nested = literalRedactor.sanitizeDictionary([
            "foo.bar": ["deep": "never-traversed"],
            "FOO.BAR": "UPPER_SECRET",
            "foo_bar": "keep-underscore"
        ])
        XCTAssertEqual(nested["foo.bar"], .string("[REDACTED]"))
        XCTAssertEqual(nested["FOO.BAR"], .string("[REDACTED]"))
        XCTAssertEqual(nested["foo_bar"], .string("keep-underscore"))

        // 128 combined keys across broad + exact is allowed; 129 fails closed.
        let broad64 = Set((0..<64).map { "broad_\($0)" })
        let exact64 = Set((0..<64).map { "exact_\($0)" })
        let atLimit = DebugBundleRedactor(sensitiveKeys: broad64, exactKeys: exact64)
        XCTAssertTrue(atLimit.isValidConfiguration)
        XCTAssertEqual(atLimit.sanitizeJSON(.object(["exact_1": .string("s"), "safe": .string("ok")])),
                       .object(["exact_1": .string("[REDACTED]"), "safe": .string("ok")]))

        let overLimit = DebugBundleRedactor(sensitiveKeys: broad64, exactKeys: exact64.union(["overflow"]))
        XCTAssertFalse(overLimit.isValidConfiguration)
        XCTAssertEqual(overLimit.sanitizeJSON(.object(["safe": .string("ok")])), .string("[REDACTED]"))
        XCTAssertEqual(overLimit.sanitizeDictionary(["safe": "ok"]), ["_redacted": .string("[REDACTED]")])
        XCTAssertEqual(overLimit.sanitizeContextDictionary(["safe": "ok"]), ["_redacted": .string("[REDACTED]")])

        // Empty, whitespace-only, or >64 byte exact keys fail closed.
        for invalidExact in [Set([""]), Set(["   "]), Set([String(repeating: "k", count: 65)])] {
            let bad = DebugBundleRedactor(sensitiveKeys: [], exactKeys: invalidExact)
            XCTAssertFalse(bad.isValidConfiguration)
            XCTAssertEqual(bad.sanitizeJSON(.string("safe")), .string("[REDACTED]"))
            XCTAssertNil(bad.sanitizeProtocolString("safe"))
        }

        // Exact config helper preserves existing defaults and chains cleanly.
        let configured = DebugBundleConfig(projectToken: "token", service: "ios")
            .withRedactExactFields(["tag", "reference"])
        XCTAssertEqual(configured.redactExactFields, ["tag", "reference"])
        XCTAssertEqual(configured.redactFields, DebugBundleConfig.defaultRedactFields)
    }

    func testBroadRedactFieldsPreservesValidatedProtocolStructuresWhileRedactingApplicationData() throws {
        let redactor = DebugBundleRedactor(sensitiveKeys: ["tag", "reference", "reason", "file"])
        let failureRef = "11111111-1111-4111-8111-111111111111"
        let opId = "22222222-2222-4222-8222-222222222222"
        let attemptId = "33333333-3333-4333-8333-333333333333"
        let sourceEventId = "44444444-4444-4444-8444-444444444444"
        let evidenceRef: JSONValue = .object([
            "version": .number(1),
            "failure_ref": .string(failureRef),
            "scope": .object(["kind": .string("operation"), "operation_id": .string(opId)])
        ])
        let evidenceLimits: JSONValue = .object([
            "version": .number(1),
            "exception_evidence": .string("budget_exceeded")
        ])

        // 1. Frontend exception with browser_event, rejection_reason, exception_evidence, resource_observations,
        //    context.evidence_reference, context.evidence_limits, and colliding application context.
        let frontend = DebugBundleEventEnvelope(
            sdkName: "@debugbundle/sdk-swift",
            sdkVersion: "3.1.5",
            service: "checkout-ios",
            environment: "production",
            eventType: DebugBundleEventType.frontendException,
            occurredAt: "2026-10-28T00:00:00Z",
            correlation: DebugBundleCorrelation(requestId: "req-1", traceId: "trace-1", sessionId: "sess-1", userIdHash: nil),
            payload: [
                "name": .string("TypeError"),
                "message": .string("failed tag=SECRET_MSG"),
                "stack": .string("at submit (https://example.test/app.js?tag=SECRET_STACK&ok=1:10:2)"),
                "device": .object(canonicalSwiftDevice(DebugBundleDeviceContext(osName: "iOS", osVersion: "18"), payload: [:])),
                "breadcrumbs": .array([
                    .object([
                        "breadcrumb_type": .string("custom"),
                        "data": .object(["tag": .string("BREADCRUMB_SECRET"), "safe": .string("ok")]),
                        "ts": .string("2026-10-28T00:00:00Z")
                    ])
                ]),
                "browser_event": .object([
                    "kind": .string("resource_error"),
                    "message": .string("load failed reason=SECRET_REASON"),
                    "file_name": .string("https://cdn.example/app.js?file=SECRET_FILE&keep=ok"),
                    "line_number": .number(12),
                    "column_number": .number(4),
                    "target": .object([
                        "tag_name": .string("script"),
                        "source_url": .string("https://cdn.example/bundle.js?tag=SECRET_TAG&v=1"),
                        "attributes": .object([
                            "rel": .string("preload tag=SECRET_ATTR"),
                            "type": .string("module"),
                            "async": .bool(true),
                            "integrity_present": .bool(false)
                        ])
                    ]),
                    "page": .object([
                        "url": .string("https://app.example/checkout?reference=SECRET_REF&step=2"),
                        "referrer": .string("https://app.example/cart?token=SECRET_TOK"),
                        "ready_state": .string("complete"),
                        "visibility_state": .string("visible")
                    ]),
                    "opaque": .bool(false)
                ]),
                "rejection_reason": .object([
                    "kind": .string("error"),
                    "name": .string("PayoutError"),
                    "message": .string("rejected reference=SECRET_REF"),
                    "preview": .string("tag=SECRET_TAG")
                ]),
                "exception_evidence": .object([
                    "version": .number(1),
                    "runtime": .string("swift"),
                    "root_id": .number(0),
                    "nodes": .array([
                        .object([
                            "id": .number(0),
                            "name": .string("OuterError"),
                            "message": .string("outer tag=SECRET_NODE"),
                            "stack": .string("at main (https://example.test/main.js?reference=SECRET_REF&v=1)"),
                            "trace_origin": .string("capture"),
                            "parsing_status": .string("parsed"),
                            "frames": .array([
                                .object([
                                    "function": .string("submit tag=SECRET_FN"),
                                    "file": .string("https://example.test/checkout.js?file=SECRET_FILE&v=2"),
                                    "line": .number(42),
                                    "column": .number(7),
                                    "classification": .string("application")
                                ])
                            ]),
                            "relationships": .array([])
                        ])
                    ]),
                    "truncated": .bool(false),
                    "unavailable_reason": .string("unsupported")
                ]),
                "resource_observations": .object([
                    "version": .number(1),
                    "items": .array([
                        .object([
                            "kind": .string("timing"),
                            "observed_at": .string("2026-10-28T00:00:00Z"),
                            "source_url": .string("https://cdn.example/app.js"),
                            "availability": .string("observed"),
                            "response_status": .number(200),
                            "duration_ms": .number(15.5),
                            "transfer_size_bytes": .number(1024)
                        ]),
                        .object([
                            "kind": .string("csp"),
                            "observed_at": .string("2026-10-28T00:00:00Z"),
                            "source_url": .string("/assets/app.js"),
                            "effective_directive": .string("script-src"),
                            "disposition": .string("enforce"),
                            "document_status_code": .number(200)
                        ])
                    ])
                ])
            ],
            device: DebugBundleDeviceContext(osName: "iOS", osVersion: "18"),
            releaseChannel: "production",
            appVersion: "1.0.0",
            buildNumber: "1",
            context: [
                "evidence_reference": evidenceRef,
                "evidence_limits": evidenceLimits,
                "payout": .object([
                    "tag": .string("SECRET_TAG"),
                    "reference": .string("SECRET_REF"),
                    "reason": .string("SECRET_REASON"),
                    "file": .string("SECRET_FILE"),
                    "safe": .string("keep")
                ])
            ]
        )

        XCTAssertTrue(isValidBeforeSendEvent(frontend))
        let safeFrontend = try XCTUnwrap(protectDebugBundleEvent(frontend, redactor: redactor))
        XCTAssertTrue(isValidBeforeSendEvent(safeFrontend))

        // Protocol fields preserved while nested strings/URLs scrubbed:
        XCTAssertEqual(safeFrontend.context?["evidence_reference"], evidenceRef)
        XCTAssertEqual(safeFrontend.context?["evidence_limits"], evidenceLimits)
        XCTAssertEqual(safeFrontend.payload["device"]?.objectValue?["color_scheme_preference"], .null)

        let safeBrowserEvent = try XCTUnwrap(safeFrontend.payload["browser_event"]?.objectValue)
        XCTAssertEqual(safeBrowserEvent["message"], .string("load failed reason=[REDACTED]"))
        XCTAssertEqual(safeBrowserEvent["file_name"], .string("https://cdn.example/app.js?file=%5BREDACTED%5D&keep=ok"))
        XCTAssertEqual(safeBrowserEvent["target"]?.objectValue?["tag_name"], .string("script"))
        XCTAssertEqual(safeBrowserEvent["target"]?.objectValue?["source_url"], .string("https://cdn.example/bundle.js?tag=%5BREDACTED%5D&v=1"))
        XCTAssertEqual(safeBrowserEvent["target"]?.objectValue?["attributes"]?.objectValue?["rel"], .string("preload tag=[REDACTED]"))
        XCTAssertEqual(safeBrowserEvent["page"]?.objectValue?["url"], .string("https://app.example/checkout?reference=%5BREDACTED%5D&step=2"))
        XCTAssertEqual(safeBrowserEvent["page"]?.objectValue?["referrer"], .string("https://app.example/cart?token=%5BREDACTED%5D"))

        let safeRejection = try XCTUnwrap(safeFrontend.payload["rejection_reason"]?.objectValue)
        XCTAssertEqual(safeRejection["kind"], .string("error"))
        XCTAssertEqual(safeRejection["message"], .string("rejected reference=[REDACTED]"))
        XCTAssertEqual(safeRejection["preview"], .string("tag=[REDACTED]"))

        let safeGraph = try XCTUnwrap(safeFrontend.payload["exception_evidence"]?.objectValue)
        XCTAssertEqual(safeGraph["unavailable_reason"], .string("unsupported"))
        let safeNode = try XCTUnwrap(safeGraph["nodes"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(safeNode["message"], .string("outer tag=[REDACTED]"))
        XCTAssertEqual(safeNode["stack"], .string("at main (https://example.test/main.js?reference=%5BREDACTED%5D&v=1)"))
        let safeFrame = try XCTUnwrap(safeNode["frames"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(safeFrame["function"], .string("submit tag=[REDACTED]"))
        XCTAssertEqual(safeFrame["file"], .string("https://example.test/checkout.js?file=%5BREDACTED%5D&v=2"))
        XCTAssertEqual(safeFrontend.payload["resource_observations"]?.objectValue?["items"]?.arrayValue?.count, 2)

        // Application-owned context & breadcrumbs NEVER exempted:
        let safePayout = try XCTUnwrap(safeFrontend.context?["payout"]?.objectValue)
        XCTAssertEqual(safePayout["tag"], .string("[REDACTED]"))
        XCTAssertEqual(safePayout["reference"], .string("[REDACTED]"))
        XCTAssertEqual(safePayout["reason"], .string("[REDACTED]"))
        XCTAssertEqual(safePayout["file"], .string("[REDACTED]"))
        XCTAssertEqual(safePayout["safe"], .string("keep"))
        XCTAssertEqual(safeFrontend.payload["breadcrumbs"]?.arrayValue?.first?.objectValue?["data"]?.objectValue?["tag"], .string("[REDACTED]"))

        // Non-HTML tag_name inside browser_event.target must NOT bypass redactFields: ["tag"].
        var nonHTML = frontend
        var customBrowserEvent = try XCTUnwrap(nonHTML.payload["browser_event"]?.objectValue)
        customBrowserEvent["target"] = .object(["tag_name": .string("custom-secret-tag"), "source_url": .null])
        nonHTML.payload["browser_event"] = .object(customBrowserEvent)
        let safeNonHTML = try XCTUnwrap(protectDebugBundleEvent(nonHTML, redactor: redactor))
        XCTAssertEqual(safeNonHTML.payload["browser_event"]?.objectValue?["target"]?.objectValue?["tag_name"], .string("[REDACTED]"))

        // Null target in browser_event is preserved cleanly.
        var nullTarget = frontend
        var nullTargetBrowser = try XCTUnwrap(nullTarget.payload["browser_event"]?.objectValue)
        nullTargetBrowser["target"] = .null
        nullTarget.payload["browser_event"] = .object(nullTargetBrowser)
        let safeNullTarget = try XCTUnwrap(protectDebugBundleEvent(nullTarget, redactor: redactor))
        XCTAssertEqual(safeNullTarget.payload["browser_event"]?.objectValue?["target"], .null)

        // 2. Backend exception with execution block & exception_evidence.
        let backend = DebugBundleEventEnvelope(
            sdkName: "@debugbundle/sdk-node",
            sdkVersion: "3.1.5",
            service: "payout-api",
            environment: "production",
            eventType: "backend_exception",
            occurredAt: "2026-10-28T00:00:00Z",
            correlation: nil,
            payload: [
                "name": .string("Error"),
                "message": .string("job failed"),
                "stack": .string("Error: job failed"),
                "handled": .bool(false),
                "request": .object(["method": .string("POST"), "path": .string("/payout"), "query": .object(["tag": .string("SECRET")]), "headers": .object(["x-file": .string("SECRET")])]),
                "response": .object(["status_code": .number(500)]),
                "runtime": .object(["version": .string("22.0.0")]),
                "execution": .object([
                    "version": .number(1),
                    "kind": .string("job"),
                    "name": .string("payout-sync reference=SECRET_REF"),
                    "elapsed_ms": .number(120),
                    "limit_ms": .number(5000)
                ])
            ],
            device: DebugBundleDeviceContext(),
            releaseChannel: "production",
            appVersion: nil,
            buildNumber: nil
        )
        XCTAssertTrue(isValidBeforeSendEvent(backend))
        let safeBackend = try XCTUnwrap(protectDebugBundleEvent(backend, redactor: redactor))
        XCTAssertTrue(isValidBeforeSendEvent(safeBackend))
        XCTAssertEqual(safeBackend.payload["execution"]?.objectValue?["name"], .string("payout-sync reference=[REDACTED]"))
        XCTAssertEqual(safeBackend.payload["request"]?.objectValue?["query"]?.objectValue?["tag"], .string("[REDACTED]"))
        XCTAssertEqual(safeBackend.payload["request"]?.objectValue?["headers"]?.objectValue?["x-file"], .string("[REDACTED]"))

        // 3. Diagnostic context (recovery + resource_observation) and invalid diagnostic context rejection.
        let recoveryDiag = DebugBundleEventEnvelope(
            sdkName: "@debugbundle/sdk-swift",
            sdkVersion: "3.1.5",
            service: "checkout-ios",
            environment: "production",
            eventType: "diagnostic_context",
            occurredAt: "2026-10-28T00:00:00Z",
            correlation: nil,
            payload: [
                "version": .number(1),
                "kind": .string("recovery"),
                "failure_ref": .string(failureRef),
                "scope": .object(["kind": .string("operation"), "operation_id": .string(opId)]),
                "attempt_id": .string(attemptId),
                "state": .string("recovery_observed"),
                "operation": .string("retry tag=SECRET_OP"),
                "status_code": .number(200),
                "duration_ms": .number(45.0)
            ],
            device: DebugBundleDeviceContext(),
            releaseChannel: "production",
            appVersion: nil,
            buildNumber: nil
        )
        let safeRecovery = try XCTUnwrap(protectDebugBundleEvent(recoveryDiag, redactor: redactor))
        XCTAssertEqual(safeRecovery.payload["operation"], .string("retry tag=[REDACTED]"))
        XCTAssertEqual(safeRecovery.payload["failure_ref"], .string(failureRef))

        let resourceDiag = DebugBundleEventEnvelope(
            sdkName: "@debugbundle/sdk-swift",
            sdkVersion: "3.1.5",
            service: "checkout-ios",
            environment: "production",
            eventType: "diagnostic_context",
            occurredAt: "2026-10-28T00:00:00Z",
            correlation: nil,
            payload: [
                "version": .number(1),
                "kind": .string("resource_observation"),
                "failure_ref": .string(failureRef),
                "scope": .object(["kind": .string("operation"), "operation_id": .string(opId)]),
                "source_event_id": .string(sourceEventId),
                "observations": try XCTUnwrap(frontend.payload["resource_observations"])
            ],
            device: DebugBundleDeviceContext(),
            releaseChannel: "production",
            appVersion: nil,
            buildNumber: nil
        )
        let safeResourceDiag = try XCTUnwrap(protectDebugBundleEvent(resourceDiag, redactor: redactor))
        XCTAssertEqual(safeResourceDiag.payload["source_event_id"], .string(sourceEventId))

        var invalidDiag = recoveryDiag
        invalidDiag.payload["kind"] = .string("unexpected")
        XCTAssertNil(protectDebugBundleEvent(invalidDiag, redactor: redactor))

        // 4. error_suppressed preserves protocol reason == "queue_pressure", but redacts spoofed reason.
        let suppressed = DebugBundleEventEnvelope(
            sdkName: "@debugbundle/sdk-swift",
            sdkVersion: "3.1.5",
            service: "checkout-ios",
            environment: "production",
            eventType: DebugBundleEventType.errorSuppressed,
            occurredAt: "2026-10-28T00:00:00Z",
            correlation: nil,
            payload: [
                "fingerprint": .string("fp-1"),
                "suppressed_count": .number(5),
                "window_seconds": .number(60),
                "first_seen": .string("2026-10-28T00:00:00Z"),
                "last_seen": .string("2026-10-28T00:00:01Z"),
                "reason": .string("queue_pressure"),
                "device": .object(canonicalSwiftDevice(DebugBundleDeviceContext(), payload: [:]))
            ],
            device: DebugBundleDeviceContext(),
            releaseChannel: "production",
            appVersion: nil,
            buildNumber: nil
        )
        let safeSuppressed = try XCTUnwrap(protectDebugBundleEvent(suppressed, redactor: redactor))
        XCTAssertEqual(safeSuppressed.payload["reason"], .string("queue_pressure"))
        XCTAssertTrue(isValidBeforeSendEvent(safeSuppressed))

        // 5. Spoofed context.evidence_reference and context.evidence_limits are NOT exempted.
        let spoofedLog = DebugBundleEventEnvelope(
            sdkName: "@debugbundle/sdk-swift",
            sdkVersion: "3.1.5",
            service: "checkout-ios",
            environment: "production",
            eventType: DebugBundleEventType.logEvent,
            occurredAt: "2026-10-28T00:00:00Z",
            correlation: nil,
            payload: [
                "level": .string("error"),
                "message": .string("spoof check"),
                "attributes": .object([:]),
                "device": .object(canonicalSwiftDevice(DebugBundleDeviceContext(), payload: [:]))
            ],
            device: DebugBundleDeviceContext(),
            releaseChannel: "production",
            appVersion: nil,
            buildNumber: nil,
            context: [
                "evidence_reference": .object(["version": .number(1), "reference": .string("SPOOFED_SECRET")]),
                "evidence_limits": .object(["version": .number(1), "reason": .string("SPOOFED_SECRET")])
            ]
        )
        let safeSpoofed = try XCTUnwrap(protectDebugBundleEvent(spoofedLog, redactor: redactor))
        XCTAssertEqual(safeSpoofed.context?["evidence_reference"], .string("[REDACTED]"))
        XCTAssertEqual(safeSpoofed.context?["evidence_limits"]?.objectValue?["reason"], .string("[REDACTED]"))
    }

    func testClientEndToEndWithBroadRedactFieldsAndExactRedactFields() async throws {
        // End-to-end 1: Broad redactFields preserves protocol evidence_reference & exception_evidence
        // while redacting colliding custom context & re-scrubbing beforeSend mutations.
        let transport1 = RecordingTransport()
        let failureRef = UUID().uuidString.lowercased()
        let broadConfig = DebugBundleConfig(
            projectToken: "token",
            service: "checkout-ios",
            flushInterval: 60,
            redactFields: ["tag", "reference", "reason", "file"],
            beforeSend: { input in
                var mutated = input
                mutated.context?["hook_payout"] = .object([
                    "tag": .string("HOOK_TAG_SECRET"),
                    "reference": .string("HOOK_REF_SECRET")
                ])
                return mutated
            }
        ).withEvidenceOptions(.init(
            captureExceptionEvidence: true,
            captureRecoveryObservations: true,
            evidenceCapabilities: .init(features: DebugBundleEvidenceCapabilities.known)
        ))
        let client1 = makeIsolatedClient(
            config: broadConfig,
            transport: transport1,
            remoteConfigClient: PrivacyAllowDiagnosticsConfig(),
            random: { 0 }
        )
        await client1.refreshRemoteConfig()
        let underlying = NSError(domain: "Upstream", code: 502, userInfo: [
            NSLocalizedDescriptionKey: "upstream tag=CAUSE_SECRET token=MANDATORY_SECRET"
        ])
        let rootError = NSError(domain: "Checkout", code: 500, userInfo: [
            NSLocalizedDescriptionKey: "checkout failed reference=ROOT_SECRET",
            NSUnderlyingErrorKey: underlying
        ])
        var scopeWire: JSONValue?
        client1.withOperationContext {
            scopeWire = client1.evidence.operations.current()?.wire
            var ctx = DebugBundleEvidenceContext.forFailure(failureRef)
            ctx["payout"] = [
                "tag": "PAYOUT_TAG",
                "reference": "PAYOUT_REF",
                "reason": "PAYOUT_REASON",
                "file": "PAYOUT_FILE",
                "currency": "USD"
            ]
            client1.captureException(rootError, context: ctx)
        }
        await client1.flush()
        withExtendedLifetime(rootError) {}

        let broadEvents = await transport1.recordedBatches().flatMap { $0 }
        let broadEvent = try XCTUnwrap(broadEvents.first)
        XCTAssertTrue(isValidBeforeSendEvent(broadEvent))
        XCTAssertEqual(broadEvent.payload["message"], .string("checkout failed reference=[REDACTED]"))
        XCTAssertEqual(broadEvent.context?["evidence_reference"]?.objectValue?["failure_ref"], .string(failureRef))
        XCTAssertEqual(broadEvent.context?["evidence_reference"]?.objectValue?["scope"], scopeWire)
        XCTAssertEqual(broadEvent.context?["payout"]?.objectValue?["tag"], .string("[REDACTED]"))
        XCTAssertEqual(broadEvent.context?["payout"]?.objectValue?["reference"], .string("[REDACTED]"))
        XCTAssertEqual(broadEvent.context?["payout"]?.objectValue?["reason"], .string("[REDACTED]"))
        XCTAssertEqual(broadEvent.context?["payout"]?.objectValue?["file"], .string("[REDACTED]"))
        XCTAssertEqual(broadEvent.context?["payout"]?.objectValue?["currency"], .string("USD"))
        XCTAssertEqual(broadEvent.context?["hook_payout"]?.objectValue?["tag"], .string("[REDACTED]"))
        XCTAssertEqual(broadEvent.context?["hook_payout"]?.objectValue?["reference"], .string("[REDACTED]"))
        let nodes = try XCTUnwrap(broadEvent.payload["exception_evidence"]?.objectValue?["nodes"]?.arrayValue)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[1].objectValue?["message"], .string("upstream tag=[REDACTED] token=[REDACTED]"))
        XCTAssertEqual(broadEvent.payload["exception_evidence"]?.objectValue?["unavailable_reason"], .null)

        // End-to-end 2: redactExactFields redacts exact keys while preserving compound siblings across log/request/context/beforeSend.
        let transport2 = RecordingTransport()
        let exactConfig = DebugBundleConfig(
            projectToken: "token",
            service: "checkout-ios",
            flushInterval: 60,
            redactFields: [],
            redactExactFields: ["tag", "x-tag"],
            headerAllowlist: DebugBundleConfig.defaultHeaderAllowlist.union(["x-tag", "x-tag-name"]),
            beforeSend: { input in
                var mutated = input
                if mutated.eventType == DebugBundleEventType.logEvent {
                    mutated.context?["tag"] = .string("HOOK_EXACT_SECRET")
                    mutated.context?["tag_name"] = .string("script")
                }
                return mutated
            }
        )
        let client2 = makeIsolatedClient(config: exactConfig, transport: transport2, random: { 0 })
        client2.setContext("tag", value: "PERSISTENT_EXACT_SECRET")
        client2.setContext("tag_name", value: "script")
        client2.captureLog(
            "exact check tag=MSG_SECRET tag_name=script x-tag=HDR_SECRET x-tag-name=keep token=MANDATORY",
            level: .error,
            context: [
                "payout": ["tag": "NESTED_SECRET", "tag_name": "img"],
                "user_token": "MANDATORY_BROAD"
            ]
        )
        client2.captureRequest(
            DebugBundleRequestInfo(
                method: "GET",
                url: "https://api.example.test/items?tag=URL_SECRET&tag_name=script&token=MANDATORY",
                headers: ["x-tag": "HDR_SECRET", "x-tag-name": "keep-header"]
            ),
            response: DebugBundleResponseInfo(statusCode: 500, durationMillis: 25)
        )
        await client2.flush()

        let exactEvents = await transport2.recordedBatches().flatMap { $0 }
        let logEvent = try XCTUnwrap(exactEvents.first { $0.eventType == DebugBundleEventType.logEvent })
        XCTAssertEqual(
            logEvent.payload["message"],
            .string("exact check tag=[REDACTED] tag_name=script x-tag=[REDACTED] x-tag-name=keep token=[REDACTED]")
        )
        let logAttrs = try XCTUnwrap(logEvent.payload["attributes"]?.objectValue)
        XCTAssertEqual(logAttrs["tag"], .string("[REDACTED]"))
        XCTAssertEqual(logAttrs["tag_name"], .string("script"))
        XCTAssertEqual(logAttrs["payout"]?.objectValue?["tag"], .string("[REDACTED]"))
        XCTAssertEqual(logAttrs["payout"]?.objectValue?["tag_name"], .string("img"))
        XCTAssertEqual(logAttrs["user_token"], .string("[REDACTED]"))
        XCTAssertEqual(logEvent.context?["tag"], .string("[REDACTED]"))
        XCTAssertEqual(logEvent.context?["tag_name"], .string("script"))

        let reqEvent = try XCTUnwrap(exactEvents.first { $0.eventType == DebugBundleEventType.requestEvent })
        XCTAssertEqual(reqEvent.payload["query"]?.objectValue?["tag"], .string("[REDACTED]"))
        XCTAssertEqual(reqEvent.payload["query"]?.objectValue?["tag_name"], .string("script"))
        XCTAssertEqual(reqEvent.payload["query"]?.objectValue?["token"], .string("[REDACTED]"))
        XCTAssertEqual(reqEvent.payload["headers"]?.objectValue?["x-tag"], .string("[REDACTED]"))
        XCTAssertEqual(reqEvent.payload["headers"]?.objectValue?["x-tag-name"], .string("keep-header"))
    }
}

private struct PrivacyAllowDiagnosticsConfig: DebugBundleRemoteConfigClienting {
    func fetch(request: DebugBundleRemoteConfigRequest) async -> DebugBundleRemoteConfigResult {
        var policy = DebugBundleRemoteCapturePolicy(preset: "balanced")
        policy.captureDiagnosticContext = true
        return .loaded(.init(capturePolicy: policy), eTag: nil)
    }
}
