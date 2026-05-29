// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "debugbundle-swift",
    platforms: [
        .iOS(.v15),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "DebugBundle",
            targets: ["DebugBundle"]
        ),
        .library(
            name: "DebugBundleURLSession",
            targets: ["DebugBundleURLSession"]
        ),
        .library(
            name: "DebugBundleAlamofire",
            targets: ["DebugBundleAlamofire"]
        ),
        .library(
            name: "DebugBundleUIKit",
            targets: ["DebugBundleUIKit"]
        ),
        .library(
            name: "DebugBundleSwiftUI",
            targets: ["DebugBundleSwiftUI"]
        ),
        .library(
            name: "DebugBundleCrashReporter",
            targets: ["DebugBundleCrashReporter"]
        ),
        .library(
            name: "DebugBundleSwiftLog",
            targets: ["DebugBundleSwiftLog"]
        ),
        .library(
            name: "DebugBundleTestSupport",
            targets: ["DebugBundleTestSupport"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0")
    ],
    targets: [
        .target(
            name: "DebugBundle"
        ),
        .target(
            name: "DebugBundleURLSession",
            dependencies: ["DebugBundle"]
        ),
        .target(
            name: "DebugBundleAlamofire",
            dependencies: [
                "DebugBundle",
                "DebugBundleURLSession",
                .product(name: "Alamofire", package: "Alamofire")
            ]
        ),
        .target(
            name: "DebugBundleUIKit",
            dependencies: ["DebugBundle"]
        ),
        .target(
            name: "DebugBundleSwiftUI",
            dependencies: ["DebugBundle"]
        ),
        .target(
            name: "DebugBundleObjCExceptionShim",
            publicHeadersPath: "include"
        ),
        .target(
            name: "DebugBundleCrashReporter",
            dependencies: [
                "DebugBundle",
                "DebugBundleObjCExceptionShim"
            ]
        ),
        .target(
            name: "DebugBundleSwiftLog",
            dependencies: [
                "DebugBundle",
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .target(
            name: "DebugBundleTestSupport",
            dependencies: ["DebugBundle"]
        ),
        .testTarget(
            name: "DebugBundleTests",
            dependencies: [
                "DebugBundle",
                "DebugBundleCrashReporter",
                "DebugBundleAlamofire",
                "DebugBundleUIKit",
                "DebugBundleSwiftUI",
                "DebugBundleSwiftLog",
                "DebugBundleURLSession",
                "DebugBundleTestSupport",
                .product(name: "Alamofire", package: "Alamofire"),
                .product(name: "Logging", package: "swift-log")
            ]
        )
    ]
)