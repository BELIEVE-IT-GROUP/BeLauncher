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
        // La capa de app no tenía pruebas: borrar el filtro de exclusiones entero de
        // BrowserHistory dejaba las 839 pruebas en verde, porque ninguna las ejecutaba.
        .testTarget(
            name: "BeLauncherAppTests",
            dependencies: ["BeLauncher", "BeLauncherCore"]
        ),
    ]
)
