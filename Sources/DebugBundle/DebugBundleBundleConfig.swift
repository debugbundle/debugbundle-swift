import Foundation

public struct DebugBundleRuntimeConfiguration: Sendable {
    public var projectToken: String?
    public var enabled: Bool?
    public var environment: String?
    public var service: String?
    public var endpoint: URL?
    public var releaseChannel: String?
    public var appVersion: String?
    public var buildNumber: String?
    public var fileProtection: DebugBundleFileProtection?

    public init(
        projectToken: String? = nil,
        enabled: Bool? = nil,
        environment: String? = nil,
        service: String? = nil,
        endpoint: URL? = nil,
        releaseChannel: String? = nil,
        appVersion: String? = nil,
        buildNumber: String? = nil,
        fileProtection: DebugBundleFileProtection? = nil
    ) {
        self.projectToken = projectToken
        self.enabled = enabled
        self.environment = environment
        self.service = service
        self.endpoint = endpoint
        self.releaseChannel = releaseChannel
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.fileProtection = fileProtection
    }
}

public extension DebugBundleConfig {
    init(
        bundle: Bundle = .main,
        runtimeConfiguration: DebugBundleRuntimeConfiguration? = nil
    ) {
        self.init(
            projectToken: runtimeConfiguration?.projectToken ?? bundle.debugBundleProjectToken,
            enabled: runtimeConfiguration?.enabled ?? bundle.debugBundleEnabled ?? true,
            environment: runtimeConfiguration?.environment ?? bundle.debugBundleEnvironment ?? "production",
            service: runtimeConfiguration?.service ?? bundle.debugBundleService ?? "ios-app",
            endpoint: runtimeConfiguration?.endpoint ?? bundle.debugBundleEndpoint ?? DebugBundleConfig.defaultEndpoint,
            releaseChannel: runtimeConfiguration?.releaseChannel ?? bundle.debugBundleReleaseChannel ?? "production",
            appVersion: runtimeConfiguration?.appVersion ?? bundle.debugBundleAppVersion,
            buildNumber: runtimeConfiguration?.buildNumber ?? bundle.debugBundleBuildNumber,
            fileProtection: runtimeConfiguration?.fileProtection ?? bundle.debugBundleFileProtection ?? .completeUntilFirstUserAuthentication
        )
    }
}

public extension Bundle {
    var debugBundleProjectToken: String {
        debugBundleInfoString(for: "DebugBundleProjectToken") ?? ""
    }

    var debugBundleEnabled: Bool? {
        debugBundleInfoValue(for: "DebugBundleEnabled") as? Bool
    }

    var debugBundleEnvironment: String? {
        debugBundleInfoString(for: "DebugBundleEnvironment")
    }

    var debugBundleService: String? {
        debugBundleInfoString(for: "DebugBundleService") ?? bundleIdentifier
    }

    var debugBundleEndpoint: URL? {
        guard
            let value = debugBundleInfoString(for: "DebugBundleEndpoint"),
            let url = URL(string: value),
            let scheme = url.scheme,
            !scheme.isEmpty,
            url.host != nil
        else {
            return nil
        }
        return url
    }

    var debugBundleReleaseChannel: String? {
        debugBundleInfoString(for: "DebugBundleReleaseChannel")
    }

    var debugBundleAppVersion: String? {
        debugBundleInfoString(for: "CFBundleShortVersionString")
    }

    var debugBundleBuildNumber: String? {
        debugBundleInfoString(for: "CFBundleVersion")
    }

    var debugBundleFileProtection: DebugBundleFileProtection? {
        guard let value = debugBundleInfoString(for: "DebugBundleFileProtection") else {
            return nil
        }
        return DebugBundleFileProtection(rawValue: value)
    }

    private func debugBundleInfoString(for key: String) -> String? {
        guard let value = debugBundleInfoValue(for: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func debugBundleInfoValue(for key: String) -> Any? {
        object(forInfoDictionaryKey: key) ?? infoDictionary?[key]
    }
}