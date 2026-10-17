// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SafeSync",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SafeSync", targets: ["SafeSyncApp"])],
    targets: [
        .target(name: "SafeSyncCore"),
        .executableTarget(name: "SafeSyncApp", dependencies: ["SafeSyncCore"]),
        .executableTarget(name: "SafeSyncChecks", dependencies: ["SafeSyncCore"]),
        .testTarget(name: "SafeSyncCoreTests", dependencies: ["SafeSyncCore"])
    ],
    swiftLanguageModes: [.v5]
)
