import Foundation
import Testing
import BeLauncherCore
@testable import BeLauncher

private final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        urls.append(url)
    }

    var value: [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls
    }
}

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
        for id in ["screen.read_context", "screen.ocr", "files.extract_pdf_text", "calendar.upcoming",
                   "system.open_app", "system.open_system_setting"] {
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

    @Test("the file chooser returns selected paths without touching the real panel in tests")
    func fileChooserAdapter() async throws {
        let definition = try #require(BELActionCatalog.named("files.choose"))
        let expected = [URL(fileURLWithPath: "/tmp/one.md"), URL(fileURLWithPath: "/tmp/two.md")]
        let chooser: @MainActor @Sendable (BELFileSelectionInput) -> [URL] = { _ in
            [URL(fileURLWithPath: "/tmp/one.md"), URL(fileURLWithPath: "/tmp/two.md")]
        }
        let handler = try #require(FileActionHandler(definition: definition, choose: chooser))
        let input = try JSONEncoder().encode(BELFileSelectionInput(multiple: true))

        let result = try await BELActionExecutor.execute(definition, input: input,
                                                         capabilities: .allGranted,
                                                         handler: handler)
        #expect(result.receipt == "file:choose")
        #expect(result.changed == expected.map(\.path))
        #expect(result.text == expected.map(\.path).joined(separator: "\n"))
    }

    @Test("cancelling the file chooser is an explicit typed failure")
    func fileChooserCancellation() async throws {
        let definition = try #require(BELActionCatalog.named("files.choose"))
        let chooser: @MainActor @Sendable (BELFileSelectionInput) -> [URL] = { _ in [] }
        let handler = try #require(FileActionHandler(definition: definition, choose: chooser))

        await #expect(throws: FileActionError.selectionCancelled) {
            try await BELActionExecutor.execute(definition, capabilities: .allGranted,
                                                handler: handler)
        }
    }

    @Test("the first public native batch is wired, and unverified app APIs stay unavailable")
    func firstPublicBatchIsHonest() throws {
        let runtime = BELActionRuntime()
        for id in ["files.choose", "files.extract_pdf_text", "screen.read_context",
                   "screen.ocr", "calendar.upcoming"] {
            let definition = try #require(BELActionCatalog.named(id))
            #expect(definition.availability == .implemented)
            #expect(runtime.handler(for: definition)?.actionID == id)
        }
        #expect(BELActionCatalog.named("reminders.create")?.availability == .implemented)
        let createList = try #require(BELActionCatalog.named("reminders.create_list"))
        #expect(createList.availability == .implemented)
        #expect(BELActionRuntime().handler(for: createList)?.actionID == createList.id)
        let reminders = try #require(BELActionCatalog.named("reminders.find"))
        #expect(reminders.availability == .implemented)
        #expect(BELActionRuntime().handler(for: reminders)?.actionID == reminders.id)
        let complete = try #require(BELActionCatalog.named("reminders.complete"))
        #expect(complete.availability == .implemented)
        #expect(BELActionRuntime().handler(for: complete)?.actionID == complete.id)
        let list = try #require(BELActionCatalog.named("reminders.show_list"))
        #expect(list.availability == .implemented)
        #expect(BELActionRuntime().handler(for: list)?.actionID == list.id)
        for id in ["reminders.change_list", "reminders.add_notes", "reminders.set_priority"] {
            let definition = try #require(BELActionCatalog.named(id))
            #expect(definition.availability == .implemented)
            #expect(BELActionRuntime().handler(for: definition)?.actionID == id)
        }
        let delete = try #require(BELActionCatalog.named("reminders.delete"))
        #expect(delete.availability == .implemented)
        #expect(delete.risk == .r3)
        #expect(BELActionRuntime().handler(for: delete)?.actionID == delete.id)
        let uncomplete = try #require(BELActionCatalog.named("reminders.uncomplete"))
        #expect(uncomplete.availability == .implemented)
        #expect(BELActionRuntime().handler(for: uncomplete)?.actionID == uncomplete.id)
        let openContact = try #require(BELActionCatalog.named("contacts.open"))
        #expect(openContact.availability == .implemented)
        #expect(openContact.adapter == .appleScript)
        #expect(BELActionRuntime().handler(for: openContact)?.actionID == openContact.id)
        let openPhoto = try #require(BELActionCatalog.named("photos.open"))
        #expect(openPhoto.availability == .implemented)
        #expect(openPhoto.adapter == .appleScript)
        #expect(BELActionRuntime().handler(for: openPhoto)?.actionID == openPhoto.id)
        let openReminder = try #require(BELActionCatalog.named("reminders.open"))
        #expect(openReminder.availability == .implemented)
        #expect(openReminder.adapter == .appleScript)
        #expect(BELActionRuntime().handler(for: openReminder)?.actionID == openReminder.id)
    }

    @Test("completing a reminder cannot bypass confirmation")
    func reminderCompletionUsesGate() async throws {
        let definition = try #require(BELActionCatalog.named("reminders.complete"))
        let input = try JSONEncoder().encode(BELReminderActionInput(reminderID: "missing"))
        await #expect(throws: BELActionExecutionError.confirmationRequired) {
            try await BELActionRuntime().execute(definition, input: input,
                                                 capabilities: .allGranted)
        }
    }

    @Test("reminder date input accepts human and deterministic forms")
    func reminderDateInput() throws {
        let now = Date(timeIntervalSince1970: 1_754_000_000)
        let tomorrow = try #require(ReminderDateParser.parse("tomorrow 09:00", now: now))
        #expect(Calendar.current.component(.hour, from: tomorrow) == 9)
        #expect(Calendar.current.dateComponents([.day], from: tomorrow)
                == Calendar.current.dateComponents([.day], from: Calendar.current.date(byAdding: .day, value: 1, to: now)!))
        #expect(ReminderDateParser.parse("not a date", now: now) == nil)
    }

    @Test("reminder priority accepts bilingual human values and rejects guesses")
    func reminderPriorityInput() {
        #expect(ReminderPriorityParser.parse("high") == 3)
        #expect(ReminderPriorityParser.parse("alta") == 3)
        #expect(ReminderPriorityParser.parse("muy alta") == 4)
        #expect(ReminderPriorityParser.parse("urgent") == nil)
    }

    @Test("public app actions validate identifiers and settings without opening the host")
    func publicAppActions() async throws {
        let app = try #require(BELActionCatalog.named("system.open_app"))
        let settings = try #require(BELActionCatalog.named("system.open_system_setting"))
        let opened = URLRecorder()
        let open: @MainActor @Sendable (URL) -> Bool = { url in
            opened.append(url)
            return true
        }
        let appHandler = try #require(SystemPublicActionHandler(definition: app, open: open))
        let settingsHandler = try #require(SystemPublicActionHandler(definition: settings, open: open))

        let appInput = try JSONEncoder().encode(BELOpenAppInput(identifier: "com.apple.TextEdit"))
        let settingInput = try JSONEncoder().encode(BELOpenSettingInput(pane: "Privacy_Microphone"))
        let appResult = try await BELActionExecutor.execute(app, input: appInput,
                                                             capabilities: .allGranted,
                                                             handler: appHandler)
        let settingResult = try await BELActionExecutor.execute(settings, input: settingInput,
                                                                capabilities: .allGranted,
                                                                handler: settingsHandler)
        #expect(appResult.receipt == "system:open_app")
        #expect(settingResult.receipt == "system:open_setting")
        #expect(opened.value.count == 2)
        #expect(opened.value[1].scheme == "x-apple.systempreferences")

        let bad = try JSONEncoder().encode(BELOpenSettingInput(pane: "https://example.com"))
        await #expect(throws: SystemPublicActionError.settingNotAllowed("https://example.com")) {
            try await BELActionExecutor.execute(settings, input: bad,
                                                capabilities: .allGranted,
                                                handler: settingsHandler)
        }
    }

    @Test("Shortcuts bridge reports inventory, exit failures and foreground requirements")
    @MainActor
    func shortcutBridgeIsHonest() throws {
        let runner: Shortcuts.ProcessRunner = { arguments in
            if arguments == ["list"] {
                return BELShortcutCommandResult(executableFound: true, terminationStatus: 0,
                                                stdout: "BEL • Files • Make PDF\n", stderr: "")
            }
            return BELShortcutCommandResult(executableFound: true, terminationStatus: 0,
                                            stdout: "done\n", stderr: "")
        }
        let names: [String]
        switch Shortcuts.available(using: runner) {
        case .success(let value): names = value
        case .failure(let error): throw error
        }
        #expect(names == ["BEL • Files • Make PDF"])

        let mapping = BELShortcutMapping(actionID: "files.make_pdf",
                                         shortcutName: names[0], requiresForeground: true)
        #expect(Shortcuts.validate(mapping, availableNames: Set(names)) == .availableForeground)
        #expect(Shortcuts.validate(mapping, availableNames: []) == .missing)

        let result = try Shortcuts.command(["run", names[0]], using: runner)
        #expect(result.stdout == "done\n")

        let failing: Shortcuts.ProcessRunner = { _ in
            BELShortcutCommandResult(executableFound: true, terminationStatus: 42,
                                     stdout: "", stderr: "shortcut failed")
        }
        #expect(throws: BELShortcutCommandError.failed(status: 42, detail: "shortcut failed")) {
            try Shortcuts.command(["run", names[0]], using: failing)
        }

        let missing: Shortcuts.ProcessRunner = { _ in
            BELShortcutCommandResult(executableFound: false, terminationStatus: -1,
                                     stdout: "", stderr: "")
        }
        #expect(throws: BELShortcutCommandError.toolUnavailable) {
            try Shortcuts.command(["run", names[0]], using: missing)
        }
    }

    @Test("curated App Intent catalog is stable and deep links are reversible")
    func appIntentCatalog() throws {
        #expect(BELAppIntentCatalog.curated.count == 16)
        #expect(Set(BELAppIntentCatalog.curated.map(\.id)).count == 16)
        for definition in BELAppIntentCatalog.curated {
            let url = try #require(BELAppIntentCatalog.deepLink(actionID: definition.id,
                                                                 query: "review & run"))
            #expect(BELAppIntentCatalog.actionID(from: url) == definition.id)
            #expect(url.absoluteString.contains("review%20%26%20run"))
            #expect(definition.executionMode == .foreground)
        }
        #expect(BELAppIntentCatalog.deepLink(actionID: "unknown") == nil)
        #expect(BELAppIntentCatalog.actionID(from: URL(string: "belauncher://intent/unknown")!) == nil)
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
