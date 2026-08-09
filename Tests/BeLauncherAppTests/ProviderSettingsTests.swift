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

    @Test("sync all refreshes each deep source row instead of hiding the result globally")
    @MainActor
    func syncAllPublishesPerSourceFeedback() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-sync-all-\(UUID().uuidString).sqlite3").path
        let store = try Store(path: path)
        let model = SettingsModel(store: store, appVersion: "test", updateFeedURL: nil,
                                  loadSecureState: false)
        let now = String(Date.now.timeIntervalSince1970)
        model.sourceFeedback["notes"] = "stale"
        model.onSourceSync = { source in
            #expect(source == "all")
            store.setSetting("source_last_sync_browsers", now)
            store.setSetting("source_last_count_browsers", "3")
            store.setSetting("source_last_problem_browsers", "")
            store.setSetting("source_last_sync_notes", now)
            store.setSetting("source_last_count_notes", "0")
            store.setSetting("source_last_problem_notes", "Full Disk Access is needed")
            return .failed("Full Disk Access is needed")
        }

        model.syncAllSources()
        await Task.yield()
        while model.sourceIsSyncing("all") {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.sourceFeedback["all"]?.contains("Full Disk Access") == true)
        #expect(model.sourceFeedback["browsers"]?.contains("3") == true)
        #expect(model.sourceFeedbackErrors["browsers"] == false)
        #expect(!model.sourceNeedsAttention("browsers"))
        #expect(model.sourceFeedback["notes"]?.contains("needs attention") == true)
        #expect(model.sourceFeedbackErrors["notes"] == true)
        #expect(model.sourceNeedsAttention("notes"))
    }

    @Test("sync all does not overwrite a source the person paused")
    @MainActor
    func syncAllLeavesPausedSourcesAlone() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-sync-paused-\(UUID().uuidString).sqlite3").path
        let store = try Store(path: path)
        let model = SettingsModel(store: store, appVersion: "test", updateFeedURL: nil,
                                  loadSecureState: false)
        model.setSourceEnabled("messages", false)
        model.sourceFeedback["messages"] = "old problem"
        model.sourceFeedbackErrors["messages"] = true
        model.onSourceSync = { _ in .completed(written: 0) }

        model.syncAllSources()
        await Task.yield()
        while model.sourceIsSyncing("all") {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.sourceStatusLine("messages") == L("Paused by you"))
        #expect(model.sourceFeedback["messages"] == nil)
        #expect(model.sourceFeedbackErrors["messages"] == nil)
    }
}
