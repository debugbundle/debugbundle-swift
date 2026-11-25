import Foundation

private let maxSafeProtocolInteger: Int64 = 9_007_199_254_740_991
private let allowedHTMLResourceTags: Set<String> = [
    "script", "link", "img", "audio", "video", "source", "iframe", "object", "embed", "input"
]
private let allowedReadyStates: Set<String> = ["loading", "interactive", "complete"]
private let allowedVisibilityStates: Set<String> = ["visible", "hidden", "prerender", "unloaded"]
private let allowedRejectionKinds: Set<String> = ["error", "string", "object", "null", "undefined", "unknown"]
private let allowedEvidenceLimitKeys: Set<String> = ["version", "exception_evidence", "execution", "resource_observations"]
private let allowedEvidenceLimitReasons: Set<String> = ["budget_exceeded", "unsafe", "unsupported", "unknown"]
private let allowedExceptionRuntimes: Set<String> = [
    "node", "browser", "python", "php", "jvm", "go", "ruby", "dotnet", "android", "swift", "react_native", "unknown"
]
private let allowedTraceOrigins: Set<String> = ["throw", "native_fatal", "capture", "runtime_reported", "unavailable", "unknown"]
private let allowedParsingStatuses: Set<String> = ["parsed", "partial", "unparsed", "unavailable", "truncated"]
private let allowedFrameClassifications: Set<String> = ["application", "framework", "sdk", "unknown"]
private let allowedRelationshipKinds: Set<String> = ["cause", "context", "aggregate", "suppressed"]
private let allowedExecutionKinds: Set<String> = ["request", "command", "job", "unknown"]
private let allowedRecoveryStates: Set<String> = [
    "attempt_started", "attempt_completed", "attempt_failed", "recovery_observed", "failure_persisted"
]
private let allowedTimingAvailabilities: Set<String> = ["observed", "unsupported", "no_match", "withheld", "ambiguous", "unknown"]
private let allowedBrowserEventKeys: Set<String> = [
    "kind", "message", "file_name", "line_number", "column_number", "target", "page", "opaque"
]
private let allowedTargetKeys: Set<String> = ["tag_name", "source_url", "attributes"]
private let allowedTargetAttrStringKeys = ["rel", "as", "type", "media", "cross_origin"]
private let allowedTargetAttrBoolKeys = ["async", "defer", "integrity_present"]
private let allowedTargetAttrKeys: Set<String> = Set(allowedTargetAttrStringKeys + allowedTargetAttrBoolKeys)
private let allowedPageKeys: Set<String> = ["url", "referrer", "ready_state", "visibility_state"]
private let allowedRejectionKeys: Set<String> = ["kind", "name", "message", "preview"]
private let allowedExceptionGraphKeys: Set<String> = [
    "version", "runtime", "root_id", "nodes", "truncated", "unavailable_reason"
]
private let allowedExceptionNodeKeys: Set<String> = [
    "id", "name", "message", "stack", "trace_origin", "parsing_status", "frames", "relationships"
]
private let allowedExceptionFrameKeys: Set<String> = ["function", "file", "line", "column", "classification"]
private let allowedRelationshipKeys: Set<String> = ["kind", "target_id"]
private let allowedExecutionKeys: Set<String> = ["version", "kind", "name", "elapsed_ms", "limit_ms"]
private let allowedResourceObsKeys: Set<String> = ["version", "items"]
private let allowedTimingObsKeys: Set<String> = [
    "kind", "observed_at", "source_url", "availability", "response_status", "duration_ms", "transfer_size_bytes"
]
private let allowedCSPObsKeys: Set<String> = [
    "kind", "observed_at", "source_url", "effective_directive", "disposition", "document_status_code"
]
private let allowedRecoveryKeys: Set<String> = [
    "version", "kind", "failure_ref", "scope", "attempt_id", "state", "operation", "status_code", "duration_ms"
]
private let allowedResourceDiagKeys: Set<String> = [
    "version", "kind", "failure_ref", "scope", "source_event_id", "observations"
]

private func exactProtocolInt(_ value: JSONValue?, min: Int64, max: Int64) -> Int64? {
    guard case let .number(number) = value,
          number.isFinite, number.rounded() == number,
          number >= Double(min), number <= Double(max) else { return nil }
    return Int64(number)
}

private func nonNegativeProtocolNumber(_ value: JSONValue?) -> Bool {
    guard case let .number(number) = value, number.isFinite, number >= 0 else { return false }
    return true
}

private func scrubNullableProtocolString(_ value: JSONValue?, redactor: DebugBundleRedactor, maxBytes: Int? = nil) -> JSONValue? {
    guard let value else { return nil }
    if value == .null { return .null }
    guard case let .string(text) = value,
          let scrubbed = redactor.sanitizeProtocolString(text) else { return nil }
    if let maxBytes, scrubbed.utf8.prefix(maxBytes + 1).count > maxBytes { return nil }
    return .string(scrubbed)
}

func isValidDebugBundleEvidenceLimits(_ value: JSONValue) -> Bool {
    guard case let .object(map) = value,
          map["version"] == .number(1),
          Set(map.keys).isSubset(of: allowedEvidenceLimitKeys) else { return false }
    for (key, entry) in map where key != "version" {
        guard let reason = entry.stringValue, allowedEvidenceLimitReasons.contains(reason) else { return false }
    }
    return true
}

func sanitizeExceptionEvidenceBlock(_ raw: JSONValue, redactor: DebugBundleRedactor) -> JSONValue? {
    guard case let .object(graph) = raw,
          Set(graph.keys) == allowedExceptionGraphKeys,
          graph["version"] == .number(1),
          let runtime = graph["runtime"]?.stringValue, allowedExceptionRuntimes.contains(runtime),
          exactProtocolInt(graph["root_id"], min: 0, max: 7) != nil,
          case .bool = graph["truncated"],
          let rawNodes = graph["nodes"]?.arrayValue, (1...8).contains(rawNodes.count) else { return nil }
    if let unavailable = graph["unavailable_reason"], unavailable != .null {
        guard let reason = unavailable.stringValue, allowedEvidenceLimitReasons.contains(reason) else { return nil }
    }
    var nodes: [JSONValue] = []
    for item in rawNodes {
        guard case let .object(node) = item,
              Set(node.keys) == allowedExceptionNodeKeys,
              exactProtocolInt(node["id"], min: 0, max: 7) != nil,
              let rawName = node["name"]?.stringValue,
              let rawMessage = node["message"]?.stringValue,
              let traceOrigin = node["trace_origin"]?.stringValue, allowedTraceOrigins.contains(traceOrigin),
              let parsingStatus = node["parsing_status"]?.stringValue, allowedParsingStatuses.contains(parsingStatus),
              let rawFrames = node["frames"]?.arrayValue, rawFrames.count <= 32,
              let rawRelationships = node["relationships"]?.arrayValue, rawRelationships.count <= 5,
              let name = redactor.sanitizeProtocolString(rawName), name.utf8.prefix(257).count <= 256,
              let message = redactor.sanitizeProtocolString(rawMessage), message.utf8.prefix(2049).count <= 2048,
              let stack = scrubNullableProtocolString(node["stack"], redactor: redactor, maxBytes: 16_384) else { return nil }
        var frames: [JSONValue] = []
        for rawFrame in rawFrames {
            guard case let .object(frame) = rawFrame,
                  Set(frame.keys) == allowedExceptionFrameKeys,
                  let fn = scrubNullableProtocolString(frame["function"], redactor: redactor, maxBytes: 256),
                  let file = scrubNullableProtocolString(frame["file"], redactor: redactor, maxBytes: 2048),
                  frame["line"] == .null || exactProtocolInt(frame["line"], min: 1, max: maxSafeProtocolInteger) != nil,
                  frame["column"] == .null || exactProtocolInt(frame["column"], min: 0, max: maxSafeProtocolInteger) != nil,
                  let classification = frame["classification"]?.stringValue, allowedFrameClassifications.contains(classification) else { return nil }
            frames.append(.object([
                "function": fn, "file": file, "line": frame["line"]!, "column": frame["column"]!,
                "classification": .string(classification)
            ]))
        }
        var relationships: [JSONValue] = []
        for rawEdge in rawRelationships {
            guard case let .object(edge) = rawEdge,
                  Set(edge.keys) == allowedRelationshipKeys,
                  let kind = edge["kind"]?.stringValue, allowedRelationshipKinds.contains(kind),
                  exactProtocolInt(edge["target_id"], min: 0, max: 7) != nil else { return nil }
            relationships.append(.object(["kind": .string(kind), "target_id": edge["target_id"]!]))
        }
        nodes.append(.object([
            "id": node["id"]!, "name": .string(name), "message": .string(message), "stack": stack,
            "trace_origin": .string(traceOrigin), "parsing_status": .string(parsingStatus),
            "frames": .array(frames), "relationships": .array(relationships)
        ]))
    }
    let result: JSONValue = .object([
        "version": .number(1), "runtime": .string(runtime), "root_id": graph["root_id"]!,
        "nodes": .array(nodes), "truncated": graph["truncated"]!, "unavailable_reason": graph["unavailable_reason"]!
    ])
    return DebugBundleEvidenceWire.graph(result, checkByteBudget: false) ? result : nil
}

func sanitizeExecutionBlock(_ raw: JSONValue, redactor: DebugBundleRedactor) -> JSONValue? {
    guard case let .object(execution) = raw,
          Set(execution.keys) == allowedExecutionKeys,
          execution["version"] == .number(1),
          let kind = execution["kind"]?.stringValue, allowedExecutionKinds.contains(kind),
          let name = scrubNullableProtocolString(execution["name"], redactor: redactor, maxBytes: 128),
          execution["elapsed_ms"] == .null || nonNegativeProtocolNumber(execution["elapsed_ms"]),
          execution["limit_ms"] == .null || nonNegativeProtocolNumber(execution["limit_ms"]) else { return nil }
    return .object([
        "version": .number(1), "kind": .string(kind), "name": name,
        "elapsed_ms": execution["elapsed_ms"]!, "limit_ms": execution["limit_ms"]!
    ])
}

func sanitizeResourceObservationsBlock(_ raw: JSONValue, redactor: DebugBundleRedactor) -> JSONValue? {
    guard case let .object(obs) = raw,
          Set(obs.keys) == allowedResourceObsKeys,
          obs["version"] == .number(1),
          let rawItems = obs["items"]?.arrayValue, (1...5).contains(rawItems.count) else { return nil }
    var items: [JSONValue] = []
    for rawItem in rawItems {
        guard case let .object(item) = rawItem,
              let kind = item["kind"]?.stringValue,
              let observedAt = item["observed_at"]?.stringValue, DebugBundleCanonicalEventSchema.timestamp(observedAt),
              let sourceURL = scrubNullableProtocolString(item["source_url"], redactor: redactor, maxBytes: 2048) else { return nil }
        if kind == "timing" {
            guard Set(item.keys) == allowedTimingObsKeys,
                  let availability = item["availability"]?.stringValue, allowedTimingAvailabilities.contains(availability),
                  item["response_status"] == .null || exactProtocolInt(item["response_status"], min: 100, max: 599) != nil,
                  item["duration_ms"] == .null || nonNegativeProtocolNumber(item["duration_ms"]),
                  item["transfer_size_bytes"] == .null || exactProtocolInt(item["transfer_size_bytes"], min: 0, max: maxSafeProtocolInteger) != nil else { return nil }
            items.append(.object([
                "kind": .string("timing"), "observed_at": .string(observedAt), "source_url": sourceURL,
                "availability": .string(availability), "response_status": item["response_status"]!,
                "duration_ms": item["duration_ms"]!, "transfer_size_bytes": item["transfer_size_bytes"]!
            ]))
        } else if kind == "csp" {
            guard Set(item.keys) == allowedCSPObsKeys,
                  let directive = item["effective_directive"]?.stringValue,
                  let disposition = item["disposition"]?.stringValue, ["enforce", "report"].contains(disposition),
                  item["document_status_code"] == .null || exactProtocolInt(item["document_status_code"], min: 100, max: 599) != nil else { return nil }
            items.append(.object([
                "kind": .string("csp"), "observed_at": .string(observedAt), "source_url": sourceURL,
                "effective_directive": .string(directive), "disposition": .string(disposition),
                "document_status_code": item["document_status_code"]!
            ]))
        } else { return nil }
    }
    let result: JSONValue = .object(["version": .number(1), "items": .array(items)])
    return DebugBundleEvidenceWire.resources(result) ? result : nil
}

func sanitizeBrowserEventBlock(_ raw: JSONValue, redactor: DebugBundleRedactor) -> JSONValue? {
    guard case let .object(event) = raw,
          Set(event.keys).isSubset(of: allowedBrowserEventKeys),
          let kind = event["kind"]?.stringValue, ["window_error", "resource_error"].contains(kind),
          case let .bool(opaque)? = event["opaque"],
          event["line_number"] == .null || exactProtocolInt(event["line_number"], min: 0, max: maxSafeProtocolInteger) != nil,
          event["column_number"] == .null || exactProtocolInt(event["column_number"], min: 0, max: maxSafeProtocolInteger) != nil,
          let message = scrubNullableProtocolString(event["message"], redactor: redactor),
          let fileName = scrubNullableProtocolString(event["file_name"], redactor: redactor),
          let rawTarget = event["target"] else { return nil }
    let targetOut: JSONValue
    if rawTarget == .null {
        targetOut = .null
    } else {
        guard case let .object(target) = rawTarget,
              Set(target.keys).isSubset(of: allowedTargetKeys),
              let rawTag = target["tag_name"],
              let sourceURL = scrubNullableProtocolString(target["source_url"], redactor: redactor) else { return nil }
        let tagOut: JSONValue
        if rawTag == .null {
            tagOut = .null
        } else if case let .string(tagString) = rawTag {
            if allowedHTMLResourceTags.contains(tagString.lowercased()) {
                tagOut = .string(tagString)
            } else {
                guard let sanitized = redactor.sanitizeProtocolJSON(.object(["tag_name": .string(tagString)])),
                      let scrubbedTag = sanitized.objectValue?["tag_name"]?.stringValue else { return nil }
                tagOut = .string(scrubbedTag)
            }
        } else { return nil }
        var targetDict: [String: JSONValue] = ["tag_name": tagOut, "source_url": sourceURL]
        if let rawAttrs = target["attributes"] {
            guard case let .object(attrs) = rawAttrs, Set(attrs.keys).isSubset(of: allowedTargetAttrKeys) else { return nil }
            var attrsOut: [String: JSONValue] = [:]
            for key in allowedTargetAttrStringKeys {
                if let val = attrs[key] {
                    guard case let .string(str) = val, let scrubbed = redactor.sanitizeProtocolString(str) else { return nil }
                    attrsOut[key] = .string(scrubbed)
                }
            }
            for key in allowedTargetAttrBoolKeys {
                if let val = attrs[key] {
                    guard case .bool = val else { return nil }
                    attrsOut[key] = val
                }
            }
            targetDict["attributes"] = .object(attrsOut)
        }
        targetOut = .object(targetDict)
    }
    var out: [String: JSONValue] = [
        "kind": .string(kind), "message": message, "file_name": fileName,
        "line_number": event["line_number"]!, "column_number": event["column_number"]!,
        "target": targetOut, "opaque": .bool(opaque)
    ]
    if let rawPage = event["page"] {
        guard case let .object(page) = rawPage, Set(page.keys) == allowedPageKeys,
              let url = scrubNullableProtocolString(page["url"], redactor: redactor),
              let referrer = scrubNullableProtocolString(page["referrer"], redactor: redactor),
              page["ready_state"] == .null || (page["ready_state"]?.stringValue.map(allowedReadyStates.contains) == true),
              page["visibility_state"] == .null || (page["visibility_state"]?.stringValue.map(allowedVisibilityStates.contains) == true) else { return nil }
        out["page"] = .object([
            "url": url, "referrer": referrer,
            "ready_state": page["ready_state"]!, "visibility_state": page["visibility_state"]!
        ])
    }
    return .object(out)
}

func sanitizeRejectionReasonBlock(_ raw: JSONValue, redactor: DebugBundleRedactor) -> JSONValue? {
    guard case let .object(reason) = raw,
          Set(reason.keys).isSubset(of: allowedRejectionKeys),
          let kind = reason["kind"]?.stringValue, allowedRejectionKinds.contains(kind) else { return nil }
    var out: [String: JSONValue] = ["kind": .string(kind)]
    for field in ["name", "message", "preview"] {
        if let rawVal = reason[field] {
            guard case let .string(text) = rawVal, !text.isEmpty,
                  let scrubbed = redactor.sanitizeProtocolString(text), !scrubbed.isEmpty else { return nil }
            out[field] = .string(scrubbed)
        }
    }
    return .object(out)
}

func sanitizeDiagnosticContextPayload(_ raw: [String: JSONValue], redactor: DebugBundleRedactor) -> [String: JSONValue]? {
    guard raw["version"] == .number(1),
          DebugBundleEvidenceWire.freshId(raw["failure_ref"]?.stringValue),
          DebugBundleEvidenceWire.scope(raw["scope"]),
          let kind = raw["kind"]?.stringValue else { return nil }
    if kind == "recovery" {
        guard Set(raw.keys).isSubset(of: allowedRecoveryKeys),
              DebugBundleEvidenceWire.freshId(raw["attempt_id"]?.stringValue),
              let state = raw["state"]?.stringValue, allowedRecoveryStates.contains(state) else { return nil }
        var out: [String: JSONValue] = [
            "version": .number(1), "kind": .string("recovery"),
            "failure_ref": raw["failure_ref"]!, "scope": raw["scope"]!,
            "attempt_id": raw["attempt_id"]!, "state": .string(state)
        ]
        if let rawOp = raw["operation"] {
            guard case let .string(op) = rawOp,
                  let scrubbed = redactor.sanitizeProtocolString(op),
                  scrubbed.utf8.prefix(65).count <= 64 else { return nil }
            out["operation"] = .string(scrubbed)
        }
        if let status = raw["status_code"] {
            guard exactProtocolInt(status, min: 100, max: 599) != nil else { return nil }
            out["status_code"] = status
        }
        if let duration = raw["duration_ms"] {
            guard nonNegativeProtocolNumber(duration) else { return nil }
            out["duration_ms"] = duration
        }
        return out
    }
    if kind == "resource_observation" {
        guard Set(raw.keys) == allowedResourceDiagKeys,
              let sourceEventId = raw["source_event_id"]?.stringValue,
              DebugBundleCanonicalEventSchema.uuid(sourceEventId),
              let rawObs = raw["observations"],
              let safeObs = sanitizeResourceObservationsBlock(rawObs, redactor: redactor) else { return nil }
        return [
            "version": .number(1), "kind": .string("resource_observation"),
            "failure_ref": raw["failure_ref"]!, "scope": raw["scope"]!,
            "source_event_id": .string(sourceEventId), "observations": safeObs
        ]
    }
    return nil
}

/// Preserves validated closed SDK protocol structures while protecting captured application data (SEC-23a).
func protectDebugBundleEvent(_ original: DebugBundleEventEnvelope, redactor: DebugBundleRedactor) -> DebugBundleEventEnvelope? {
    protectDebugBundleEvent(original, redactor: redactor, allowEvidenceFallback: true)
}

private func protectDebugBundleEvent(
    _ original: DebugBundleEventEnvelope,
    redactor: DebugBundleRedactor,
    allowEvidenceFallback: Bool
) -> DebugBundleEventEnvelope? {
    guard redactor.isValidConfiguration else { return nil }
    func string(_ value: String) -> String? {
        redactor.sanitizeProtocolString(value)
    }
    func optionalString(_ value: String?) -> String? {
        value.flatMap(string)
    }
    func fallback() -> DebugBundleEventEnvelope? {
        guard allowEvidenceFallback, debugBundleIsException(original.eventType) else { return nil }
        let reduced = DebugBundleIngestionWire.withoutEvidence(original)
        guard reduced != original else { return nil }
        return protectDebugBundleEvent(reduced, redactor: redactor, allowEvidenceFallback: false)
    }
    for identity in [original.schemaVersion, original.sdkName, original.sdkVersion, original.correlation?.traceId, original.correlation?.requestId, original.correlation?.sessionId, original.correlation?.userIdHash].compactMap({ $0 }) {
        guard string(identity) == identity else { return nil }
    }

    var rawPayload = original.payload
    var preservedPayload: [String: JSONValue] = [:]
    var diagnosticPayload: [String: JSONValue]? = nil

    if original.eventType == "diagnostic_context" {
        guard let safeDiagnostic = sanitizeDiagnosticContextPayload(rawPayload, redactor: redactor) else {
            return nil
        }
        diagnosticPayload = safeDiagnostic
    } else {
        if original.eventType == DebugBundleEventType.frontendException {
            if let browserEvent = rawPayload["browser_event"],
               let safeBrowserEvent = sanitizeBrowserEventBlock(browserEvent, redactor: redactor) {
                preservedPayload["browser_event"] = safeBrowserEvent
                rawPayload.removeValue(forKey: "browser_event")
            }
            if let rejectionReason = rawPayload["rejection_reason"],
               let safeRejectionReason = sanitizeRejectionReasonBlock(rejectionReason, redactor: redactor) {
                preservedPayload["rejection_reason"] = safeRejectionReason
                rawPayload.removeValue(forKey: "rejection_reason")
            }
            if let observations = rawPayload["resource_observations"],
               let safeObservations = sanitizeResourceObservationsBlock(observations, redactor: redactor) {
                preservedPayload["resource_observations"] = safeObservations
                rawPayload.removeValue(forKey: "resource_observations")
            }
        }
        if debugBundleIsException(original.eventType),
           let graph = rawPayload["exception_evidence"],
           let safeGraph = sanitizeExceptionEvidenceBlock(graph, redactor: redactor) {
            preservedPayload["exception_evidence"] = safeGraph
            rawPayload.removeValue(forKey: "exception_evidence")
        }
        if original.eventType == "backend_exception",
           let execution = rawPayload["execution"],
           let safeExecution = sanitizeExecutionBlock(execution, redactor: redactor) {
            preservedPayload["execution"] = safeExecution
            rawPayload.removeValue(forKey: "execution")
        }
        if original.eventType == DebugBundleEventType.errorSuppressed,
           rawPayload["reason"] == .string("queue_pressure") {
            preservedPayload["reason"] = .string("queue_pressure")
            rawPayload.removeValue(forKey: "reason")
        }
    }

    var rawContext = original.context ?? [:]
    var preservedContext: [String: JSONValue] = [:]
    if original.context != nil {
        if let ref = rawContext["evidence_reference"], DebugBundleEvidenceWire.reference(ref) {
            preservedContext["evidence_reference"] = ref
            rawContext.removeValue(forKey: "evidence_reference")
        }
        if let limits = rawContext["evidence_limits"], isValidDebugBundleEvidenceLimits(limits) {
            preservedContext["evidence_limits"] = limits
            rawContext.removeValue(forKey: "evidence_limits")
        }
    }

    guard let payloadCandidate = diagnosticPayload == nil
        ? redactor.sanitizeProtocolJSON(.object(rawPayload))
        : .object([:]),
          case let .object(sanitizedPayload) = payloadCandidate,
          let service = string(original.service),
          let environment = string(original.environment),
          let runtime = string(original.serviceRuntime),
          let releaseChannel = string(original.releaseChannel) else { return fallback() }

    var event = original
    event.payload = diagnosticPayload ?? sanitizedPayload.merging(preservedPayload) { _, preserved in preserved }
    if original.context != nil {
        guard let contextCandidate = redactor.sanitizeProtocolJSON(.object(rawContext)),
              case let .object(sanitizedContext) = contextCandidate else { return fallback() }
        event.context = sanitizedContext.merging(preservedContext) { _, preserved in preserved }
    }
    event.service = service
    event.environment = environment
    event.serviceRuntime = runtime
    event.serviceRuntimeIsAbsent = original.serviceRuntimeIsAbsent
    event.releaseChannel = releaseChannel
    event.appVersion = optionalString(original.appVersion)
    event.buildNumber = optionalString(original.buildNumber)
    event.serviceFramework = optionalString(original.serviceFramework)
    var device = original.device
    device.appVersion = optionalString(device.appVersion)
    device.buildNumber = optionalString(device.buildNumber)
    device.releaseChannel = optionalString(device.releaseChannel)
    device.osName = optionalString(device.osName)
    device.osVersion = optionalString(device.osVersion)
    device.manufacturer = optionalString(device.manufacturer)
    device.model = optionalString(device.model)
    device.deviceType = optionalString(device.deviceType)
    device.screenResolution = optionalString(device.screenResolution)
    device.locale = optionalString(device.locale)
    device.timezone = optionalString(device.timezone)
    device.networkConnectionType = optionalString(device.networkConnectionType)
    event.device = device

    var assembled: [String: JSONValue] = [
        "payload": .object(event.payload),
        "service": .object(["name": .string(service), "environment": .string(environment)])
    ]
    if let context = event.context {
        assembled["context"] = .object(context)
    }
    guard let assembledBytes = try? JSONEncoder().encode(JSONValue.object(assembled)),
          assembledBytes.count <= DebugBundleTelemetryPrivacy.maxProtectedBytes else {
        return fallback()
    }

    // Legacy remote probe activations may carry non-UUID correlation labels. Preserve their
    // existing envelope behavior while rejecting sanitation that invalidates a valid shape.
    if isValidBeforeSendEvent(original) && !isValidBeforeSendEvent(event) {
        return fallback()
    }
    return event
}
