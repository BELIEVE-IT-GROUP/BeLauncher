// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BeLauncher",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "BeLauncherCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "BeLauncher",
            dependencies: ["BeLauncherCore"]
        ),
        .testTarget(
            name: "BeLauncherCoreTests",
            dependencies: ["BeLauncherCore"]
        ),
    ]
)
