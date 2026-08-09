import Foundation
import Testing
import BeLauncherCore
@testable import BeLauncher

@Suite("Native BEL adapters")
struct BELSystemCommandHandlerTests {
    @Test("the existing closed system commands execute through stable BEL IDs")
    @MainActor
    func systemCommandBridge() async throws {
        let definition = try #require(BELActionCatalog.named("brain.open"))
        let handler = try #require(SystemCommandActionHandler(definition: definition))

        let result = try await BELActionExecutor.execute(definition,
                                                         capabilities: .allGranted,
                                                         handler: handler)
        #expect(result.receipt == "system:openBrain")
        #expect(handler.actionID == definition.id)
    }

    @Test("the adapter refuses AI and unavailable definitions")
    func adapterDoesNotPretend() throws {
        let ai = try #require(BELActionCatalog.named("ai.verb.summarise"))
        #expect(SystemCommandActionHandler(definition: ai) == nil)

        let unavailable = BELActionDefinition(id: "future.native", kind: .native,
                                              titleKey: "future.native", aliases: ["future"],
                                              risk: .r0, adapter: .none,
                                              availability: .unavailable)
        #expect(SystemCommandActionHandler(definition: unavailable) == nil)
    }

    @Test("the app runtime cannot bypass the central confirmation gate")
    func runtimeUsesGate() async throws {
        let definition = try #require(BELActionCatalog.named("files.empty_trash"))
        let runtime = BELActionRuntime()

        await #expect(throws: BELActionExecutionError.confirmationRequired) {
            try await runtime.execute(definition, capabilities: .allGranted)
        }
    }

    @Test("user shortcuts are stable actions and require confirmation")
    func shortcutActionUsesGate() async throws {
        let definition = try #require(BELActionCatalog.named("shortcuts.run"))
        let input = try JSONEncoder().encode(BELShortcutActionInput(name: "Focus"))
        let runtime = BELActionRuntime()

        await #expect(throws: BELActionExecutionError.confirmationRequired) {
            try await runtime.execute(definition, input: input, capabilities: .allGranted)
        }
    }

    @Test("stable Shortcut mappings survive persistence and resolve by BEL ID")
    @MainActor
    func shortcutMappingPersistence() throws {
        let key = "bel_shortcut_mappings"
        let old = UserDefaults.standard.data(forKey: key)
        defer {
            if let old { UserDefaults.standard.set(old, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try Shortcuts.saveMapping(BELShortcutMapping(
            actionID: "calendar.upcoming", shortcutName: "BEL • Upcoming meetings"))
        #expect(ShortcutMappingStore.name(for: "calendar.upcoming") == "BEL • Upcoming meetings")
        #expect(ShortcutMappingStore.name(for: "missing.action") == nil)
    }

    @Test("public API actions are wired to concrete handlers")
    func publicAdaptersAreRegistered() throws {
        let runtime = BELActionRuntime()
        for id in ["screen.read_context", "screen.ocr", "files.extract_pdf_text", "calendar.upcoming"] {
            let definition = try #require(BELActionCatalog.named(id))
            #expect(runtime.handler(for: definition)?.actionID == id)
        }
    }

    @Test("every implemented action resolves through its declared adapter")
    func everyImplementedActionHasAHandler() throws {
        let runtime = BELActionRuntime()
        let implemented = BELActionCatalog.all.filter {
            $0.availability == .implemented && $0.kind == .native
        }

        #expect(!implemented.isEmpty)
        for definition in implemented {
            #expect(runtime.handler(for: definition)?.actionID == definition.id,
                    "missing handler for \(definition.id) via \(definition.adapter.rawValue)")
        }
    }

    @Test("native resolution order is explicit and public APIs lead")
    func nativeResolutionOrder() {
        #expect(BELActionRuntime.nativeAdapterOrder == [
            .publicAPI, .ownAppIntent, .shortcut, .urlScheme, .appleScript, .allowlistedShell,
        ])
    }

    @Test("permission-sensitive public actions stop at the central gate")
    func publicAdaptersRespectCapabilities() async throws {
        let runtime = BELActionRuntime()
        let ocr = try #require(BELActionCatalog.named("screen.ocr"))
        let calendar = try #require(BELActionCatalog.named("calendar.upcoming"))

        await #expect(throws: BELActionExecutionError.blocked(.missingCapability(.screenRecording))) {
            try await runtime.execute(ocr, capabilities: BELCapabilitySnapshot())
        }
        await #expect(throws: BELActionExecutionError.blocked(.missingCapability(.calendar))) {
            try await runtime.execute(calendar, capabilities: BELCapabilitySnapshot())
        }
    }

    @Test("every unavailable inventory seed is blocked before execution")
    func unavailableSeedsCannotExecute() async throws {
        let runtime = BELActionRuntime()

        for definition in BELActionCatalog.all where definition.availability == .unavailable {
            await #expect(throws: BELActionExecutionError.blocked(.unavailable)) {
                try await runtime.execute(definition, capabilities: .allGranted, confirmed: true)
            }
        }
    }

    #if canImport(AppIntents)
    @Test("App Intents publish the complete curated command surface")
    @MainActor
    func appIntentsBridge() async throws {
        var received: Set<String> = []
        let center = NotificationCenter.default
        let names = [
            BELAppIntentNotification.openBrain,
            BELAppIntentNotification.showClipboard,
            BELAppIntentNotification.openSettings,
            BELAppIntentNotification.recordVoice,
            BELAppIntentNotification.dictate,
            BELAppIntentNotification.readScreen,
            BELAppIntentNotification.quickNote,
            BELAppIntentNotification.recordCall,
            BELAppIntentNotification.searchBrain,
            BELAppIntentNotification.upcomingMeetings,
            BELAppIntentNotification.focus,
            BELAppIntentNotification.prepareMeeting,
            BELAppIntentNotification.openNotes,
            BELAppIntentNotification.openGraph,
            BELAppIntentNotification.transcribeLastVoice,
            BELAppIntentNotification.openLauncher,
        ]
        let observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                received.insert(name.rawValue)
            }
        }
        defer { observers.forEach(center.removeObserver) }

        _ = try await OpenBrainIntent().perform()
        _ = try await ShowClipboardIntent().perform()
        _ = try await OpenBeLauncherSettingsIntent().perform()
        _ = try await RecordVoiceNoteIntent().perform()
        _ = try await DictateIntoCurrentAppIntent().perform()
        _ = try await ReadScreenIntent().perform()
        _ = try await WriteQuickNoteIntent().perform()
        _ = try await RecordCallIntent().perform()
        _ = try await SearchBrainIntent().perform()
        _ = try await UpcomingMeetingsIntent().perform()
        _ = try await StartFocusIntent().perform()
        _ = try await PrepareMeetingIntent().perform()
        _ = try await OpenNotesIntent().perform()
        _ = try await OpenGraphIntent().perform()
        _ = try await TranscribeLastVoiceIntent().perform()
        _ = try await OpenLauncherIntent().perform()

        #expect(received.count == names.count)
        #expect(BeLauncherShortcuts.appShortcuts.count == 16)
    }
    #endif
}
