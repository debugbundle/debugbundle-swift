import Foundation
import XCTest
@testable import DebugBundle

final class DebugBundleConfigTests: XCTestCase {
    func testBundleAndRuntimeConfigurationResolveExpectedPrecedence() throws {
        let bundle = try makeBundle(info: [
            "CFBundleIdentifier": "com.debugbundle.checkout",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
            "DebugBundleProjectToken": "bundle-token",
            "DebugBundleEnvironment": "bundle-env",
            "DebugBundleService": "checkout-ios",
            "DebugBundleEndpoint": "https://bundle.example.com/v1/events",
            "DebugBundleReleaseChannel": "testflight",
            "DebugBundleFileProtection": "completeUnlessOpen",
            "DebugBundleEnabled": true
        ])

        let runtimeConfiguration = DebugBundleRuntimeConfiguration(
            projectToken: "runtime-token",
            enabled: false,
            environment: "runtime-env",
            endpoint: URL(string: "https://runtime.example.com/v1/events"),
            fileProtection: DebugBundleFileProtection.none
        )

        let config = DebugBundleConfig(bundle: bundle, runtimeConfiguration: runtimeConfiguration)

        XCTAssertEqual(bundle.debugBundleProjectToken, "bundle-token")
        XCTAssertEqual(config.projectToken, "runtime-token")
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.environment, "runtime-env")
        XCTAssertEqual(config.service, "checkout-ios")
        XCTAssertEqual(config.endpoint, URL(string: "https://runtime.example.com/v1/events"))
        XCTAssertEqual(config.releaseChannel, "testflight")
        XCTAssertEqual(config.appVersion, "1.2.3")
        XCTAssertEqual(config.buildNumber, "42")
        XCTAssertEqual(config.fileProtection, .none)
    }

    func testBundleConfigurationFallsBackToDefaultsWhenValuesAreMissingOrInvalid() throws {
        let bundle = try makeBundle(info: [
            "CFBundleIdentifier": "com.debugbundle.checkout",
            "DebugBundleEndpoint": "not a url"
        ])

        let config = DebugBundleConfig(bundle: bundle)

        XCTAssertEqual(config.projectToken, "")
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.environment, "production")
        XCTAssertEqual(config.service, "com.debugbundle.checkout")
        XCTAssertEqual(config.endpoint, DebugBundleConfig.defaultEndpoint)
        XCTAssertEqual(config.releaseChannel, "production")
        XCTAssertNil(config.appVersion)
        XCTAssertNil(config.buildNumber)
        XCTAssertEqual(config.fileProtection, .completeUntilFirstUserAuthentication)
    }
}

private func makeBundle(info: [String: Any]) throws -> Bundle {
    let fileManager = FileManager.default
    let bundleURL = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("bundle")
    let contentsURL = bundleURL.appendingPathComponent("Contents")
    try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)

    let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
    let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try infoData.write(to: infoPlistURL)

    guard let bundle = Bundle(url: bundleURL) else {
        throw NSError(domain: "DebugBundleTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to load bundle fixture"])
    }
    return bundle
}