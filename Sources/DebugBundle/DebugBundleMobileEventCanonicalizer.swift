import CryptoKit
import Foundation

struct DebugBundleCanonicalEvent {
    var payload: [String: JSONValue]
    var context: [String: JSONValue]?
}

func canonicalizeSwiftEvent(
    eventType: String,
    payload: [String: JSONValue],
    device: DebugBundleDeviceContext,
    occurredAt: String
) -> DebugBundleCanonicalEvent {
    let canonicalDevice = JSONValue.object(canonicalSwiftDevice(device, payload: payload))
    let context = payload["context"]?.objectValue
    var canonical: [String: JSONValue]

    switch eventType {
    case DebugBundleEventType.frontendException:
        canonical = canonicalSwiftException(payload, device: canonicalDevice, occurredAt: occurredAt)
    case DebugBundleEventType.logEvent:
        canonical = canonicalSwiftLog(payload, device: canonicalDevice)
    case DebugBundleEventType.requestEvent:
        canonical = canonicalSwiftRequest(payload, device: canonicalDevice)
    case DebugBundleEventType.frontendBreadcrumb:
        canonical = canonicalSwiftBreadcrumb(payload, device: canonicalDevice)
    case DebugBundleEventType.probeEvent:
        canonical = canonicalSwiftProbe(payload, device: canonicalDevice)
    case DebugBundleEventType.errorSuppressed:
        canonical = canonicalSwiftSuppression(payload, device: canonicalDevice, occurredAt: occurredAt)
    default:
        canonical = payload
    }
    return DebugBundleCanonicalEvent(payload: canonical, context: context)
}

func deterministicLegacySwiftEventId(
    sdkName: String,
    eventType: String,
    service: String,
    occurredAt: String,
    payload: [String: JSONValue]
) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payloadData = (try? encoder.encode(payload)) ?? Data()
    let seed = [
        sdkName,
        eventType,
        service,
        occurredAt,
        payloadData.base64EncodedString()
    ].joined(separator: "\u{1f}")
    var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x40
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    let hex = bytes.map { String(format: "%02x", $0) }
    return [
        hex[0 ..< 4].joined(),
        hex[4 ..< 6].joined(),
        hex[6 ..< 8].joined(),
        hex[8 ..< 10].joined(),
        hex[10 ..< 16].joined()
    ].joined(separator: "-")
}

func swiftDeviceContext(fromCanonicalPayload payload: [String: JSONValue]) -> DebugBundleDeviceContext? {
    guard let device = payload["device"]?.objectValue else {
        return nil
    }
    let os = device["os"]?.objectValue
    let screen = device["screen"]?.objectValue
    let width = screen?["width"]?.intValue
    let height = screen?["height"]?.intValue
    let resolution: String? = if let width, let height {
        "\(width)x\(height)"
    } else {
        nil
    }
    return DebugBundleDeviceContext(
        appVersion: device["app_version"]?.stringValue,
        buildNumber: device["build_number"]?.stringValue,
        releaseChannel: device["release_channel"]?.stringValue,
        osName: os?["name"]?.stringValue,
        osVersion: os?["version"]?.stringValue,
        manufacturer: device["manufacturer"]?.stringValue,
        model: device["model"]?.stringValue,
        deviceType: device["device_type"]?.stringValue,
        screenResolution: resolution,
        locale: device["language"]?.stringValue,
        timezone: device["timezone"]?.stringValue,
        networkConnectionType: device["connection_type"]?.stringValue,
        batteryLevel: device["battery_level"]?.doubleValue,
        charging: device["battery_charging"]?.boolValue,
        freeDiskBytes: device["free_disk_bytes"]?.int64Value,
        freeMemoryBytes: device["free_memory_bytes"]?.int64Value,
        jailbroken: device["jailbroken"]?.boolValue
    )
}

private func canonicalSwiftException(
    _ payload: [String: JSONValue],
    device: JSONValue,
    occurredAt: String
) -> [String: JSONValue] {
    let error = payload["error"]?.objectValue
    let name = payload["name"]?.stringValue
        ?? error?["type"]?.stringValue
        ?? error?["domain"]?.stringValue
        ?? "Error"
    let message = nonEmpty(payload["message"]?.stringValue)
        ?? nonEmpty(error?["message"]?.stringValue)
        ?? name
    let stack = nonEmpty(payload["stack"]?.stringValue)
        ?? nonEmpty(error?["stack"]?.stringValue)
        ?? error?["stack_trace"]?.arrayValue?
            .compactMap(\.stringValue)
            .joined(separator: "\n")
            .nonEmpty
        ?? "\(name): \(message)"
    let breadcrumbs = (payload["breadcrumbs"]?.arrayValue ?? []).map { entry -> JSONValue in
        guard var breadcrumb = entry.objectValue else {
            return entry
        }
        if breadcrumb["ts"] == nil {
            breadcrumb["ts"] = breadcrumb.removeValue(forKey: "occurred_at") ?? .string(occurredAt)
        }
        return .object(breadcrumb)
    }

    var canonical: [String: JSONValue] = [
        "name": .string(name),
        "message": .string(message),
        "stack": .string(stack),
        "breadcrumbs": .array(breadcrumbs),
        "device": device
    ]
    if let route = payload["route"] {
        canonical["route"] = route
    }
    if let probeData = canonicalInlineProbeData(payload["probe_data"], occurredAt: occurredAt) {
        canonical["probe_data"] = probeData
    }
    return canonical
}

private func canonicalSwiftLog(
    _ payload: [String: JSONValue],
    device: JSONValue
) -> [String: JSONValue] {
    var attributes = payload["attributes"]?.objectValue ?? [:]
    attributes.merge(payload["context"]?.objectValue ?? [:]) { _, new in new }
    for key in ["logged_at", "thread_name", "logger", "tag", "coroutine_name", "throwable"] {
        if let value = payload[key] {
            attributes[key] = value
        }
    }
    return [
        "level": payload["level"] ?? .string("warning"),
        "message": payload["message"] ?? .string("Log event"),
        "attributes": .object(attributes),
        "device": device
    ]
}

private func canonicalSwiftRequest(
    _ payload: [String: JSONValue],
    device: JSONValue
) -> [String: JSONValue] {
    let rawURL = payload["url"]?.stringValue
    let components = rawURL.flatMap { URLComponents(string: $0) }
    let path = nonEmpty(payload["path"]?.stringValue)
        ?? nonEmpty(components?.path)
        ?? nonEmpty(rawURL)
        ?? "/"
    var query: [String: JSONValue] = payload["query"]?.objectValue ?? [:]
    if query.isEmpty {
        var values: [String: [String]] = [:]
        for item in components?.queryItems ?? [] {
            values[item.name, default: []].append(item.value ?? "")
        }
        query = values.mapValues { entries in
            entries.count == 1
                ? .string(entries[0])
                : .array(entries.map(JSONValue.string))
        }
    }
    var canonical: [String: JSONValue] = [
        "method": payload["method"] ?? .string("UNKNOWN"),
        "path": .string(path),
        "query": .object(query),
        "headers": payload["headers"]?.objectValue.map(JSONValue.object) ?? .object([:]),
        "response_status": payload["response_status"] ?? payload["status_code"] ?? .number(0),
        "duration_ms": nonNegativeNumber(payload["duration_ms"]),
        "response_headers": payload["response_headers"]?.objectValue.map(JSONValue.object) ?? .object([:]),
        "device": device
    ]
    if let routeTemplate = payload["route_template"], routeTemplate != .null {
        canonical["route_template"] = routeTemplate
    }
    if let body = payload["body"] {
        canonical["body"] = body
    }
    if let responseBody = payload["response_body"] {
        canonical["response_body"] = responseBody
    }
    return canonical
}

private func canonicalSwiftBreadcrumb(
    _ payload: [String: JSONValue],
    device: JSONValue
) -> [String: JSONValue] {
    var canonical: [String: JSONValue] = [
        "breadcrumb_type": payload["breadcrumb_type"] ?? .string("custom"),
        "data": payload["data"]?.objectValue.map(JSONValue.object) ?? .object([:]),
        "device": device
    ]
    if let route = payload["route"], route != .null {
        canonical["route"] = route
    }
    return canonical
}

private func canonicalSwiftProbe(
    _ payload: [String: JSONValue],
    device: JSONValue
) -> [String: JSONValue] {
    return [
        "label": payload["label"] ?? .string("unknown"),
        "data": objectWrapped(payload["data"]),
        "activation_id": payload["activation_id"] ?? .null,
        "probe_label_pattern": payload["probe_label_pattern"] ?? .string("*"),
        "device": device
    ]
}

private func canonicalSwiftSuppression(
    _ payload: [String: JSONValue],
    device: JSONValue,
    occurredAt: String
) -> [String: JSONValue] {
    return [
        "fingerprint": payload["fingerprint"] ?? .string("unknown"),
        "suppressed_count": payload["suppressed_count"] ?? .number(0),
        "window_seconds": payload["window_seconds"] ?? .number(1),
        "first_seen": payload["first_seen"] ?? .string(occurredAt),
        "last_seen": payload["last_seen"] ?? .string(occurredAt),
        "device": device
    ]
}

private func canonicalInlineProbeData(_ value: JSONValue?, occurredAt: String) -> JSONValue? {
    guard let value else {
        return nil
    }
    if let object = value.objectValue,
       object["version"] == .number(1),
       object["items"]?.arrayValue != nil {
        return value
    }
    guard let legacy = value.objectValue else {
        return .object([
            "version": .number(1),
            "items": .array([
                .object([
                    "label": .string("default"),
                    "data": objectWrapped(value),
                    "timestamp": .string(occurredAt),
                    "activation_id": .null
                ])
            ])
        ])
    }
    var items: [JSONValue] = []
    for label in legacy.keys.sorted() {
        let entries = legacy[label]?.arrayValue ?? [legacy[label] ?? .null]
        for entry in entries {
            items.append(
                .object([
                    "label": .string(label),
                    "data": objectWrapped(entry),
                    "timestamp": .string(occurredAt),
                    "activation_id": .null
                ])
            )
        }
    }
    return .object(["version": .number(1), "items": .array(items)])
}

private func canonicalSwiftDevice(
    _ device: DebugBundleDeviceContext,
    payload: [String: JSONValue]
) -> [String: JSONValue] {
    if let canonical = payload["device"]?.objectValue,
       canonical["os"]?.objectValue != nil {
        return canonical
    }
    let dimensions = parseScreenResolution(device.screenResolution)
    let deviceType = ["desktop", "mobile", "tablet", "unknown"].contains(device.deviceType ?? "")
        ? device.deviceType!
        : "unknown"
    return [
        "user_agent": .null,
        "os": .object([
            "name": device.osName.map(JSONValue.string) ?? .null,
            "version": device.osVersion.map(JSONValue.string) ?? .null
        ]),
        "device_type": .string(deviceType),
        "screen": .object([
            "width": .number(Double(dimensions.width)),
            "height": .number(Double(dimensions.height))
        ]),
        "viewport": .object([
            "width": .number(Double(dimensions.width)),
            "height": .number(Double(dimensions.height))
        ]),
        "device_pixel_ratio": .null,
        "touch_capable": .bool(true),
        "language": device.locale.map(JSONValue.string) ?? .null,
        "connection_type": device.networkConnectionType.map(JSONValue.string) ?? .null,
        "color_scheme_preference": .null,
        "app_version": device.appVersion.map(JSONValue.string) ?? .null,
        "build_number": device.buildNumber.map(JSONValue.string) ?? .null,
        "release_channel": device.releaseChannel.map(JSONValue.string) ?? .null,
        "api_level": .null,
        "manufacturer": device.manufacturer.map(JSONValue.string) ?? .null,
        "model": device.model.map(JSONValue.string) ?? .null,
        "timezone": device.timezone.map(JSONValue.string) ?? .null,
        "battery_level": device.batteryLevel.map(JSONValue.number) ?? .null,
        "battery_charging": device.charging.map(JSONValue.bool) ?? .null,
        "free_disk_bytes": device.freeDiskBytes.map { .number(Double(max(0, $0))) } ?? .null,
        "free_memory_bytes": device.freeMemoryBytes.map { .number(Double(max(0, $0))) } ?? .null,
        "jailbroken": device.jailbroken.map(JSONValue.bool) ?? .null
    ]
}

private func objectWrapped(_ value: JSONValue?) -> JSONValue {
    guard let value else {
        return .object(["value": .null])
    }
    if case .object = value {
        return value
    }
    return .object(["value": value])
}

private func parseScreenResolution(_ resolution: String?) -> (width: Int, height: Int) {
    guard let resolution else {
        return (0, 0)
    }
    let components = resolution
        .lowercased()
        .replacingOccurrences(of: "×", with: "x")
        .split(separator: "x", maxSplits: 1)
    guard components.count == 2,
          let width = Int(components[0].trimmingCharacters(in: .whitespaces)),
          let height = Int(components[1].trimmingCharacters(in: .whitespaces)) else {
        return (0, 0)
    }
    return (max(0, width), max(0, height))
}

private func nonNegativeNumber(_ value: JSONValue?) -> JSONValue {
    guard let number = value?.doubleValue else {
        return .number(0)
    }
    return .number(max(0, number))
}

private func nonEmpty(_ value: String?) -> String? {
    value?.nonEmpty
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else {
            return nil
        }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    var doubleValue: Double? {
        guard case let .number(value) = self else {
            return nil
        }
        return value
    }

    var intValue: Int? {
        doubleValue.map(Int.init)
    }

    var int64Value: Int64? {
        doubleValue.map(Int64.init)
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else {
            return nil
        }
        return value
    }
}
