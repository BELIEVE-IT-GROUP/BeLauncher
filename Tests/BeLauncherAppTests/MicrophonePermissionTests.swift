import Foundation
import Testing
@testable import BeLauncher

@Suite("El permiso de micrófono llega al bundle y al sistema")
struct MicrophonePermissionTests {
    private static var repositoryRoot: String {
        var path = URL(fileURLWithPath: #filePath)
        while path.pathComponents.count > 1 {
            path.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: path.appendingPathComponent("Package.swift").path) {
                return path.path
            }
        }
        return ""
    }

    @Test("Info.plist declara el uso de micrófono y audio de captura")
    func usageDescriptionsAreShipped() throws {
        let path = URL(fileURLWithPath: Self.repositoryRoot)
            .appendingPathComponent("Scripts/Info.plist")
        let data = try Data(contentsOf: path)
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let microphone = try #require(plist["NSMicrophoneUsageDescription"] as? String)
        let audio = try #require(plist["NSAudioCaptureUsageDescription"] as? String)

        #expect(!microphone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!audio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        for script in ["Scripts/bundle.sh", "Scripts/release-mac.sh"] {
            let source = try String(contentsOf: URL(fileURLWithPath: Self.repositoryRoot)
                .appendingPathComponent(script), encoding: .utf8)
            #expect(source.contains("cp \"$ROOT/Scripts/Info.plist\" \"$APP/Contents/Info.plist\""),
                    "el bundle de (script) debe copiar las declaraciones que TCC necesita")
        }
    }

    @Test("el build firmado declara Audio Input además del texto de uso")
    func audioInputEntitlementIsShippedAndVerified() throws {
        let entitlements = try String(contentsOf: URL(fileURLWithPath: Self.repositoryRoot)
            .appendingPathComponent("Scripts/BeLauncher.entitlements"), encoding: .utf8)
        let release = try String(contentsOf: URL(fileURLWithPath: Self.repositoryRoot)
            .appendingPathComponent("Scripts/release-mac.sh"), encoding: .utf8)

        #expect(entitlements.contains("com.apple.security.device.audio-input"))
        #expect(release.contains("require_entitlement \"com.apple.security.device.audio-input\""),
                "el release debe validar el binario firmado, no solo el plist fuente")
    }

    @Test("el flujo usa la autoridad del grabador sin combinar estados")
    func permissionFlowUsesRecorderAuthority() throws {
        let path = URL(fileURLWithPath: Self.repositoryRoot)
            .appendingPathComponent("Sources/BeLauncher/Permissions.swift")
        let source = try String(contentsOf: path, encoding: .utf8)

        #expect(source.contains("AVAudioApplication.shared.recordPermission"))
        #expect(source.contains("AVAudioApplication.requestRecordPermission"))
        #expect(!source.contains("AVCaptureDevice.requestAccess(for: .audio)"))
        #expect(source.contains("private static var microphoneRequest"))
        #expect(source.contains("NSApp.setActivationPolicy(.regular)"))
        #expect(source.contains("NSApp.setActivationPolicy(.accessory)"))
    }
}
