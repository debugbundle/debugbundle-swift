// swift-tools-version: 5.10
import PackageDescription

// Exercise the adapter's actual dependency floor; the package suite separately
// tests the current resolved SwiftLog release.
#if compiler(>=6.2)
let loggingFloor = "1.12.0"
#else
let loggingFloor = "1.6.0"
#endif

let package = Package(
    name: "DebugBundleSpmSmoke",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(name: "debugbundle-swift", path: "../.."),
        .package(url: "https://github.com/apple/swift-log.git", exact: Version(loggingFloor)!)
    ],
    targets: [
        .executableTarget(
            name: "DebugBundleSpmSmoke",
            dependencies: [
                .product(name: "DebugBundle", package: "debugbundle-swift"),
                .product(name: "DebugBundleSwiftLog", package: "debugbundle-swift")
            ]
        )
    ]
)
