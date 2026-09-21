import Foundation

/// Protects application-owned fields without changing typed protocol identity or event kind.
func protectDebugBundleEvent(_ original: DebugBundleEventEnvelope, redactor: DebugBundleRedactor) -> DebugBundleEventEnvelope? {
    func string(_ value: String) -> String? {
        guard case let .string(cleaned) = redactor.sanitizeJSON(.string(value)) else { return nil }
        return cleaned
    }
    func optionalString(_ value: String?) -> String? {
        value.flatMap(string)
    }
    for identity in [original.schemaVersion, original.sdkName, original.sdkVersion, original.correlation?.traceId].compactMap({ $0 }) {
        guard string(identity) == identity else { return nil }
    }
    guard case let .object(payload) = redactor.sanitizeJSON(.object(original.payload)),
          let service = string(original.service),
          let environment = string(original.environment),
          let runtime = string(original.serviceRuntime),
          let releaseChannel = string(original.releaseChannel) else { return nil }
    var event = original
    event.payload = payload
    if let context = original.context {
        guard case let .object(cleaned) = redactor.sanitizeJSON(.object(context)) else { return nil }
        event.context = cleaned
    }
    event.service = service
    event.environment = environment
    event.serviceRuntime = runtime
    event.releaseChannel = releaseChannel
    event.appVersion = optionalString(original.appVersion)
    event.buildNumber = optionalString(original.buildNumber)
    event.serviceFramework = optionalString(original.serviceFramework)
    if let trace = original.correlation?.traceId {
        guard let cleaned = string(trace) else { return nil }
        event.correlation = DebugBundleCorrelation(traceId: cleaned)
    }
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
    // Legacy remote probe activations may carry non-UUID correlation labels. Preserve their
    // existing envelope behavior while rejecting sanitation that invalidates a valid shape.
    return isValidBeforeSendEvent(original) && !isValidBeforeSendEvent(event) ? nil : event
}
