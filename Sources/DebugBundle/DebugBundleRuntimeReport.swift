import Foundation

/// Primitive native report shared only by DebugBundle-owned adapter modules.
@_spi(DebugBundleRuntime) public struct DebugBundleRuntimeReport: Sendable {
    public var eventId: String
    public var name: String
    public var message: String
    public var occurredAt: String
    public var stackTrace: [String]
    public var traceOrigin: String
    public var isCurrent = false
    public init(eventId: String, name: String, message: String, occurredAt: String, stackTrace: [String], traceOrigin: String = "unknown") {
        self.eventId = eventId; self.name = name; self.message = message; self.occurredAt = occurredAt
        self.stackTrace = stackTrace; self.traceOrigin = traceOrigin
    }
}

extension DebugBundleClient {
    @_spi(DebugBundleRuntime) @discardableResult public func captureRuntimeReport(_ report: DebugBundleRuntimeReport,
        context: [String: Any?] = [:], onRetained: (() -> Void)? = nil) -> Bool {
        guard canAdmit(priority: 3, countTowardSession: false), report.eventId.utf8.prefix(65).count <= 64,
              DebugBundleCanonicalEventSchema.uuid(report.eventId), report.occurredAt.utf8.prefix(65).count <= 64,
              DebugBundleRuntimeEvidence.validTimestamp(report.occurredAt), let date = debugBundleParseTimestamp(report.occurredAt),
              ["capture", "native_fatal", "runtime_reported", "throw", "unknown", "unavailable"].contains(report.traceOrigin) else { return false }
        var bounded = report
        bounded.name = DebugBundleRuntimeEvidence.boundedText(report.name, maximumBytes: 256, redactFields: config.redactFields)
        bounded.message = DebugBundleRuntimeEvidence.boundedText(report.message, maximumBytes: 512, redactFields: config.redactFields)
        bounded.stackTrace = report.stackTrace.prefix(32).map { DebugBundleRuntimeEvidence.boundedText($0, maximumBytes: 512, redactFields: config.redactFields) }
        let error = NSError(domain: bounded.name, code: 0, userInfo: [NSLocalizedDescriptionKey: bounded.message])
        var merged = report.isCurrent ? evidence.context(mergedContext(context)) : mergedContext(context)
        merged["stack_trace"] = JSONValue.array(bounded.stackTrace.map(JSONValue.string))
        merged["trace_origin"] = bounded.traceOrigin
        let snapshot = report.isCurrent ? exceptionContextSnapshot() : (breadcrumbs: [], probes: [:])
        var payload: [String: JSONValue] = ["error": .object(debugBundleSafeErrorPayload(error)),
            "stack": .string(Thread.callStackSymbols.joined(separator: "\n")),
            "context": .object(redactor.sanitizeDictionary(merged)), "breadcrumbs": .array(snapshot.breadcrumbs)]
        if report.isCurrent && config.probeFlushOnError { payload["probe_data"] = .object(snapshot.probes) }
        var envelope = makeEnvelope(eventType: DebugBundleEventType.frontendException, payload: payload,
            traceId: debugBundleStringValue(from: merged["trace_id"]), occurredAt: date)
        envelope.eventId = bounded.eventId
        envelope.occurredAt = bounded.occurredAt
        return capturePreparedEnvelope(envelope, deferredError: DebugBundleDeferredError(runtime: bounded),
            runBeforeSend: bounded.isCurrent, onRetained: onRetained)
    }
}

/// Fatal/retained reports deliberately inspect no relationships and use at most eight supplied frames.
enum DebugBundleFatalEvidence {
    static func capture(_ report: DebugBundleRuntimeReport, context: [String: JSONValue]?, redactor: DebugBundleRedactor) -> JSONValue? {
        var frames: [JSONValue] = [], truncated = report.stackTrace.count > 8
        for line in report.stackTrace.prefix(8) {
            guard let function = DebugBundleExceptionEvidence.parsedFunction(line) else { continue }
            if function.utf8.prefix(257).count > 256 { truncated = true }
            frames.append(.object(["function": .string(DebugBundleExceptionEvidence.clip(function, 256)), "file": .null,
                "line": .null, "column": .null, "classification": .string(function.contains("DebugBundle") ? "sdk" : "unknown")]))
        }
        while true {
            let graph: JSONValue = .object(["version": .number(1), "runtime": .string("swift"), "root_id": .number(0),
                "nodes": .array([.object(["id": .number(0), "name": .string(report.name), "message": .string(report.message),
                    "stack": .null, "trace_origin": .string(report.traceOrigin),
                    "parsing_status": .string(truncated ? "truncated" : frames.isEmpty ? (report.stackTrace.isEmpty ? "unavailable" : "unparsed") : "parsed"),
                    "frames": .array(frames), "relationships": .array([])])]), "truncated": .bool(truncated), "unavailable_reason": .string("unsafe")])
            let safe = redactor.sanitizeJSON(graph)
            var additions: [String: JSONValue] = ["exception_evidence": safe]
            if let reference = context?["evidence_reference"], DebugBundleEvidenceWire.reference(reference) { additions["evidence_reference"] = reference }
            if DebugBundleAcceptingJSONSize.bytes(.object(additions)) <= 4096 { return safe }
            guard !frames.isEmpty else { return nil }
            frames.removeLast(); truncated = true
        }
    }
}
