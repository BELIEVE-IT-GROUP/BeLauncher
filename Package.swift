// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Beacon",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "BeaconCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Beacon",
            dependencies: ["BeaconCore"]
        ),
        .testTarget(
            name: "BeaconCoreTests",
            dependencies: ["BeaconCore"]
        ),
    ]
)
