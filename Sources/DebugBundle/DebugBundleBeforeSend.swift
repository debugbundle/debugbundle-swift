import Foundation

func applyDebugBundleBeforeSend(
    _ event: DebugBundleEventEnvelope,
    hook: DebugBundleBeforeSend?
) -> DebugBundleEventEnvelope? {
    guard let hook else {
        return event
    }
    let result = hook(event)
    guard let result else {
        return nil
    }
    return isValidBeforeSendEvent(result) ? result : event
}

private func isValidBeforeSendEvent(_ event: DebugBundleEventEnvelope) -> Bool {
    guard
        event.schemaVersion == "2026-03-01",
        UUID(uuidString: event.eventId) != nil,
        !event.sdkName.isEmpty,
        !event.sdkVersion.isEmpty,
        !event.service.isEmpty,
        !event.environment.isEmpty,
        debugBundleParseTimestamp(event.occurredAt) != nil
    else {
        return false
    }

    switch event.eventType {
    case DebugBundleEventType.frontendException:
        return hasNonEmptyStrings(event.payload, ["name", "message", "stack"])
            && hasOnlyKeys(
                event.payload,
                [
                    "name", "message", "stack", "route", "browser", "breadcrumbs", "device",
                    "browser_event", "rejection_reason", "dom_context", "probe_data"
                ]
            )
    case DebugBundleEventType.frontendBreadcrumb:
        return nonEmptyString(event.payload["breadcrumb_type"])
            && event.payload["data"]?.objectValue != nil
            && hasOnlyKeys(event.payload, ["breadcrumb_type", "route", "data", "device"])
    case DebugBundleEventType.logEvent:
        return hasNonEmptyStrings(event.payload, ["level", "message"])
            && event.payload["attributes"]?.objectValue != nil
            && hasOnlyKeys(event.payload, ["level", "message", "attributes", "device"])
    case DebugBundleEventType.requestEvent:
        return hasNonEmptyStrings(event.payload, ["method", "path"])
            && event.payload["query"]?.objectValue != nil
            && event.payload["headers"]?.objectValue != nil
            && isNonNegativeNumber(event.payload["response_status"])
            && isNonNegativeNumber(event.payload["duration_ms"])
            && hasOnlyKeys(
                event.payload,
                [
                    "method", "path", "query", "headers", "body", "response_status",
                    "duration_ms", "route_template", "response_headers", "response_body", "device"
                ]
            )
    case DebugBundleEventType.errorSuppressed:
        return nonEmptyString(event.payload["fingerprint"])
            && isNonNegativeInteger(event.payload["suppressed_count"])
            && isPositiveInteger(event.payload["window_seconds"])
            && isTimestamp(event.payload["first_seen"])
            && isTimestamp(event.payload["last_seen"])
            && hasOnlyKeys(
                event.payload,
                [
                    "fingerprint", "suppressed_count", "window_seconds", "first_seen",
                    "last_seen", "device"
                ]
            )
    case DebugBundleEventType.probeEvent:
        return nonEmptyString(event.payload["label"])
            && event.payload["data"]?.objectValue != nil
            && isNullableUUID(event.payload["activation_id"])
            && nonEmptyString(event.payload["probe_label_pattern"])
            && hasOnlyKeys(
                event.payload,
                ["label", "data", "activation_id", "probe_label_pattern", "device"]
            )
    default:
        return false
    }
}

private func hasNonEmptyStrings(
    _ payload: [String: JSONValue],
    _ fields: [String]
) -> Bool {
    fields.allSatisfy { nonEmptyString(payload[$0]) }
}

private func nonEmptyString(_ value: JSONValue?) -> Bool {
    guard let value = value?.stringValue else {
        return false
    }
    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private func isNonNegativeNumber(_ value: JSONValue?) -> Bool {
    guard let value = value?.doubleValue else {
        return false
    }
    return value.isFinite && value >= 0
}

private func isNonNegativeInteger(_ value: JSONValue?) -> Bool {
    guard let value = value?.doubleValue else {
        return false
    }
    return value.isFinite && value >= 0 && value.rounded() == value
}

private func isPositiveInteger(_ value: JSONValue?) -> Bool {
    guard let value = value?.doubleValue else {
        return false
    }
    return value.isFinite && value > 0 && value.rounded() == value
}

private func isTimestamp(_ value: JSONValue?) -> Bool {
    guard let value = value?.stringValue else {
        return false
    }
    return debugBundleParseTimestamp(value) != nil
}

private func isNullableUUID(_ value: JSONValue?) -> Bool {
    if value == .null {
        return true
    }
    guard let value = value?.stringValue else {
        return false
    }
    return UUID(uuidString: value) != nil
}

private func hasOnlyKeys(
    _ payload: [String: JSONValue],
    _ allowed: Set<String>
) -> Bool {
    allowed.isSuperset(of: payload.keys)
}
