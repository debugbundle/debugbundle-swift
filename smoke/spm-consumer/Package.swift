// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DebugBundleSpmSmoke",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "DebugBundleSpmSmoke",
            dependencies: [
                .product(name: "DebugBundle", package: "debugbundle-swift")
            ]
        )
    ]
)
