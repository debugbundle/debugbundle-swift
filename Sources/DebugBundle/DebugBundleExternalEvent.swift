import Foundation

func parseDebugBundleExternalEvent(
    _ event: [String: JSONValue],
    fallbackDevice: DebugBundleDeviceContext
) -> DebugBundleEventEnvelope? {
    guard externalEventRootKeys.isSuperset(of: event.keys) else {
        return nil
    }
    guard let schemaVersion = event["schema_version"]?.stringValue,
          externalSchemaVersions.contains(schemaVersion),
          let eventId = event["event_id"]?.stringValue,
          UUID(uuidString: eventId) != nil,
          let eventType = event["event_type"]?.stringValue,
          externalEventTypes.contains(eventType),
          event["sdk_name"]?.stringValue == reactNativeSDKName,
          let sdkVersion = event["sdk_version"]?.stringValue,
          !sdkVersion.isEmpty,
          let occurredAt = event["occurred_at"]?.stringValue,
          debugBundleParseTimestamp(occurredAt) != nil,
          let service = event["service"]?.objectValue,
          externalServiceKeys.isSuperset(of: service.keys),
          let serviceName = service["name"]?.stringValue,
          !serviceName.isEmpty,
          let environment = service["environment"]?.stringValue,
          !environment.isEmpty,
          let payload = event["payload"]?.objectValue else {
        return nil
    }

    let externalDevice = event["device"]?.objectValue.flatMap(swiftDeviceContext(fromExternalDevice:))
        ?? swiftDeviceContext(fromCanonicalPayload: payload)
        ?? fallbackDevice
    let canonical = canonicalizeSwiftEvent(
        eventType: eventType,
        payload: payload,
        device: externalDevice,
        occurredAt: occurredAt
    )
    let correlation = event["correlation"]?.objectValue
    return DebugBundleEventEnvelope(
        sdkName: reactNativeSDKName,
        sdkVersion: sdkVersion,
        service: serviceName,
        environment: environment,
        eventType: eventType,
        occurredAt: occurredAt,
        correlation: correlation.map {
            DebugBundleCorrelation(traceId: nullableString($0["trace_id"]))
        },
        payload: canonical.payload,
        device: externalDevice,
        releaseChannel: externalDevice.releaseChannel ?? "production",
        appVersion: externalDevice.appVersion,
        buildNumber: externalDevice.buildNumber,
        schemaVersion: "2026-03-01",
        eventId: eventId.lowercased(),
        serviceRuntime: service["runtime"]?.stringValue ?? "react-native",
        serviceFramework: service["framework"]?.stringValue,
        context: event["context"]?.objectValue ?? canonical.context
    )
}

func shouldCaptureDebugBundleExternalEnvelope(
    config: DebugBundleConfig,
    policy: DebugBundleCapturePolicy,
    event: DebugBundleEventEnvelope
) -> Bool {
    switch event.eventType {
    case DebugBundleEventType.logEvent:
        let level = debugBundleExternalLogLevel(event.payload["level"]?.stringValue)
        return policy.capturesLog(level, localEnabled: config.captureLogs, localThreshold: config.logLevel)
    case DebugBundleEventType.requestEvent:
        guard config.captureNetwork else {
            return false
        }
        let status = event.payload["response_status"]?.intValue
            ?? event.payload["status_code"]?.intValue
            ?? 0
        let path = event.payload["path"]?.stringValue
            ?? event.payload["url"]?.stringValue
            ?? ""
        let method = event.payload["method"]?.stringValue ?? ""
        return policy.capturesStandaloneRequestEvent(status, requestPath: path, httpMethod: method)
    case DebugBundleEventType.frontendBreadcrumb:
        return policy.capturesStandaloneBreadcrumbs()
    case DebugBundleEventType.probeEvent:
        return policy.capturesStandaloneProbeEvents()
    default:
        return true
    }
}

private func swiftDeviceContext(
    fromExternalDevice device: [String: JSONValue]
) -> DebugBundleDeviceContext {
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
        osName: os?["name"]?.stringValue ?? device["os_name"]?.stringValue,
        osVersion: os?["version"]?.stringValue ?? device["os_version"]?.stringValue,
        manufacturer: device["manufacturer"]?.stringValue,
        model: device["model"]?.stringValue,
        deviceType: device["device_type"]?.stringValue,
        screenResolution: resolution ?? device["screen_resolution"]?.stringValue,
        locale: device["language"]?.stringValue ?? device["locale"]?.stringValue,
        timezone: device["timezone"]?.stringValue,
        networkConnectionType: device["connection_type"]?.stringValue,
        batteryLevel: device["battery_level"]?.doubleValue,
        charging: device["battery_charging"]?.boolValue ?? device["charging"]?.boolValue,
        freeDiskBytes: device["free_disk_bytes"]?.int64Value,
        freeMemoryBytes: device["free_memory_bytes"]?.int64Value,
        jailbroken: device["jailbroken"]?.boolValue
    )
}

private func nullableString(_ value: JSONValue?) -> String? {
    value?.stringValue
}

private func debugBundleExternalLogLevel(_ value: String?) -> DebugBundleLogLevel {
    switch value?.lowercased() {
    case "debug":
        return .debug
    case "info":
        return .info
    case "error":
        return .error
    case "critical", "fatal":
        return .critical
    default:
        return .warning
    }
}

let reactNativeSDKName = "@debugbundle/sdk-react-native"
private let externalSchemaVersions: Set<String> = ["1", "2026-03-01"]
private let externalEventTypes: Set<String> = [
    DebugBundleEventType.frontendException,
    DebugBundleEventType.frontendBreadcrumb,
    DebugBundleEventType.logEvent,
    DebugBundleEventType.requestEvent,
    DebugBundleEventType.errorSuppressed,
    DebugBundleEventType.probeEvent
]
private let externalSessionEventTypes: Set<String> = [
    DebugBundleEventType.frontendBreadcrumb,
    DebugBundleEventType.logEvent,
    DebugBundleEventType.requestEvent
]
private let externalEventRootKeys: Set<String> = [
    "schema_version",
    "event_id",
    "event_type",
    "sdk_name",
    "sdk_version",
    "service",
    "occurred_at",
    "correlation",
    "context",
    "payload",
    "device"
]
private let externalServiceKeys: Set<String> = ["name", "environment", "runtime", "framework"]

func debugBundleExternalEventCountsTowardSession(_ eventType: String) -> Bool {
    externalSessionEventTypes.contains(eventType)
}

func makeDebugBundleExternalSuppressionEvent(
    source: DebugBundleEventEnvelope,
    fingerprint: String,
    suppressedCount: Int,
    windowSeconds: Int,
    occurredAt: String
) -> DebugBundleEventEnvelope {
    let canonical = canonicalizeSwiftEvent(
        eventType: DebugBundleEventType.errorSuppressed,
        payload: [
            "fingerprint": .string(fingerprint),
            "suppressed_count": .number(Double(suppressedCount)),
            "window_seconds": .number(Double(windowSeconds)),
            "first_seen": .string(occurredAt),
            "last_seen": .string(occurredAt)
        ],
        device: source.device,
        occurredAt: occurredAt
    )
    return DebugBundleEventEnvelope(
        sdkName: source.sdkName,
        sdkVersion: source.sdkVersion,
        service: source.service,
        environment: source.environment,
        eventType: DebugBundleEventType.errorSuppressed,
        occurredAt: occurredAt,
        correlation: source.correlation,
        payload: canonical.payload,
        device: source.device,
        releaseChannel: source.releaseChannel,
        appVersion: source.appVersion,
        buildNumber: source.buildNumber,
        serviceRuntime: source.serviceRuntime,
        serviceFramework: source.serviceFramework,
        context: source.context
    )
}

func makeDebugBundleExternalProbeEvents(
    directives: [DebugBundleRemoteProbeDirective],
    sdkVersion: String,
    service: String,
    environment: String,
    label: String,
    data: JSONValue,
    occurredAt: String,
    device: DebugBundleDeviceContext
) -> [DebugBundleEventEnvelope] {
    directives.map { directive in
        let canonical = canonicalizeSwiftEvent(
            eventType: DebugBundleEventType.probeEvent,
            payload: [
                "label": .string(label),
                "data": data,
                "activation_id": .string(directive.effectiveActivationId),
                "probe_label_pattern": .string(directive.labelPattern)
            ],
            device: device,
            occurredAt: occurredAt
        )
        return DebugBundleEventEnvelope(
            sdkName: reactNativeSDKName,
            sdkVersion: sdkVersion,
            service: service,
            environment: environment,
            eventType: DebugBundleEventType.probeEvent,
            occurredAt: occurredAt,
            correlation: nil,
            payload: canonical.payload,
            device: device,
            releaseChannel: device.releaseChannel ?? "production",
            appVersion: device.appVersion,
            buildNumber: device.buildNumber,
            serviceRuntime: "react-native",
            serviceFramework: "react-native"
        )
    }
}
