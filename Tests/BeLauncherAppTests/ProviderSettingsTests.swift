import Foundation
import Testing
@testable import BeLauncher
@testable import BeLauncherCore

@Suite("Settings chooses providers that can actually answer")
struct ProviderSettingsTests {
    @Test("an offline local catalogue cannot hide a configured cloud provider")
    func offlineLocalDoesNotWin() {
        let providers = SettingsModel.configuredProviders(
            localProviderIDs: [],
            providerKeys: ["openai": "sk-user-own"]
        )

        #expect(providers.map(\.id) == ["openai"])
    }

    @Test("a detected local provider remains available without a key")
    func detectedLocalIsAvailable() {
        let providers = SettingsModel.configuredProviders(
            localProviderIDs: ["ollama"],
            providerKeys: [:]
        )

        #expect(providers.map(\.id) == ["ollama"])
    }

    @Test("source switches persist through the typed Store contract")
    @MainActor
    func sourceSwitchPersists() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-switch-\(UUID().uuidString).sqlite3").path
        let store = try Store(path: path)
        let model = SettingsModel(store: store, appVersion: "test", updateFeedURL: nil,
                                  loadSecureState: false)

        model.setSourceEnabled("notes", false)
        #expect(!model.sourceEnabled("notes"))

        model.setSourceEnabled("notes", true)
        #expect(model.sourceEnabled("notes"))
        #expect(store.setting("source_enabled_notes") == "1")
    }
}
