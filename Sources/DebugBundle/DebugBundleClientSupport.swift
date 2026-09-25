import Foundation

func debugBundleFingerprint(
    eventType: String,
    payload: [String: JSONValue]
) -> String {
    let stablePayload: JSONValue
    switch eventType {
    case DebugBundleEventType.frontendException:
        let error = payload["error"]?.objectValue ?? [:]
        stablePayload = .object([
            "type": error["type"] ?? error["domain"] ?? payload["name"] ?? .string("Error"),
            "message": error["message"] ?? payload["message"] ?? .string("")
        ])
    case DebugBundleEventType.logEvent:
        // Canonicalization keeps the capture timestamp in attributes for diagnosis, but
        // duplicate detection must remain stable across capture times.
        var attributes = (payload["context"] ?? payload["attributes"])?.objectValue ?? [:]
        attributes.removeValue(forKey: "logged_at")
        stablePayload = .object([
            "level": payload["level"] ?? .string(""),
            "message": payload["message"] ?? .string(""),
            "context": .object(attributes)
        ])
    case DebugBundleEventType.requestEvent:
        stablePayload = .object([
            "method": payload["method"] ?? .string(""),
            "url": payload["url"] ?? payload["path"] ?? .string(""),
            "status": payload["status_code"] ?? payload["response_status"] ?? .number(0)
        ])
    default:
        stablePayload = .object(payload)
    }
    return eventType + ":" + debugBundleCanonicalString(stablePayload)
}

func debugBundleTimestamp(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

func debugBundleParseTimestamp(_ value: String) -> Date? {
    if let date = ISO8601DateFormatter().date(from: value) {
        return date
    }
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractionalFormatter.date(from: value)
}

func debugBundleStringValue(from value: Any??) -> String? {
    guard let unwrapped = value ?? nil else {
        return nil
    }
    guard debugBundleIsSafeFoundationValue(unwrapped) else { return nil }
    if let value = unwrapped as? String { return value.utf8.prefix(4_097).count <= 4_096 ? value : nil }
    if type(of: unwrapped) == Int.self { return String(unwrapped as! Int) }
    return nil
}

func debugBundleDefaultQueueURL(for config: DebugBundleConfig) -> URL {
    if let offlineQueueURL = config.offlineQueueURL {
        return offlineQueueURL
    }
    let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    return baseURL
        .appendingPathComponent("DebugBundle", isDirectory: true)
        .appendingPathComponent("queue.json", isDirectory: false)
}

func debugBundleDefaultConnectivityMonitor() -> DebugBundleConnectivityMonitoring? {
    DebugBundleNWPathConnectivityMonitor()
}

let debugBundleDefaultSleep: @Sendable (TimeInterval) async -> Void = { interval in
    guard interval > 0 else {
        return
    }
    let nanoseconds = UInt64(interval * 1_000_000_000)
    try? await Task.sleep(nanoseconds: nanoseconds)
}

func debugBundleRemoteConfigRefreshInterval(_ pollIntervalMillis: Int) -> TimeInterval {
    let serverInterval = TimeInterval(pollIntervalMillis) / 1_000
    if serverInterval > 0 {
        return min(max(serverInterval, 30), 300)
    }
    return 30
}

private func debugBundleCanonicalString(_ value: JSONValue) -> String {
    switch value {
    case let .string(stringValue):
        return "\"\(stringValue)\""
    case let .number(numberValue):
        return String(numberValue)
    case let .bool(boolValue):
        return boolValue ? "true" : "false"
    case let .array(arrayValue):
        return "[" + arrayValue.map(debugBundleCanonicalString).joined(separator: ",") + "]"
    case let .object(objectValue):
        let parts = objectValue.keys.sorted().map { key in
            "\"\(key)\":" + debugBundleCanonicalString(objectValue[key] ?? .null)
        }
        return "{" + parts.joined(separator: ",") + "}"
    case .null:
        return "null"
    }
}
