import AppKit
import PDFKit
import SwiftUI
import BeLauncherCore
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchStartedAt = Date()
    private var store: Store?
    private var model: LauncherModel?
    private var panel: CommandPanel?
    private var statusItem: NSStatusItem?
    private var updateItem: NSMenuItem?
    private var awakeItem: NSMenuItem?
    private var serviceProvider: ServiceProvider?
    private var pendingRelease: Release?
    private var welcomeWindow: NSWindow?
    private var canvasWindow: NSWindow?
    private var canvasModel: CanvasModel?
    private var trayWindow: NSWindow?
    var agentRunner: AgentRunner?
    /// Held so a request that is taking too long can be called off instead of endured.
    private var aiTask: Task<Void, Never>?
    private var hotKey: HotKey?
    private var clipboardHotKey: HotKey?
    private var screenHotKey: HotKey?
    private var voiceNoteHotKey: HotKey?
    private var dictationHotKey: HotKey?
    private var callHotKey: HotKey?
    private var audioCapture: AudioCaptureController?
    private var capturePanel: CaptureStatusPanel?
    private var callCapture: CallCaptureController?
    private var callReviewWindow: NSWindow?
    private var callReviewModel: CallReviewModel?
    private var audioItem: NSMenuItem?
    private var callItem: NSMenuItem?
    private var callSuggestionItem: NSMenuItem?
    /// Whoever was in front when the launcher was summoned.
    private var appBeforePanel: NSRunningApplication?
    private var applicationActivityObserver: NSObjectProtocol?
    private var appIntentObservers: [NSObjectProtocol] = []
    private var clipboard: ClipboardWatcher?
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?
    private var keyMonitor: Any?
    private var appIndex = AppIndex()
    /// One snapshot per short typing session. Re-reading 1,000 clipboard rows, including their
    /// payloads, for every keystroke is visible on an 8 GB Mac even though the SQL itself is fast.
    private var launcherInputCache: (key: String, input: SearchInput, expires: Date)?
    private var shortcuts: [BeLauncherCore.Shortcut] = []
    private var systemShortcuts: [String] = []
    private var vault: Vault?
    private var brain: BrainSearch?
    private var lastBrainRefresh: Date?
    /// Builds the corpus in the background: episodes, entities, and the nightly distillation.
    private var corpusRunner: CorpusRunner?
    private var consentWindow: NSWindow?
    private var graphWindow: NSWindow?
    private var graphModel: GraphModel?
    private var readerWindow: NSWindow?
    private var readerModel: CorpusReaderModel?
    private var quickNoteWindow: NSWindow?
    private var lastReceipt: MissionReceipt?
    private var missionTasks: [String: Task<Void, Error>] = [:]
    private let commandCoordinator = BrainCommandCoordinator()
    private let calendar = CalendarAccess()
    private var environment: [String: String] = [:]
    private var activationWindow: NSWindow?
    private var activationModel: ActivationModel?
    private var license: LicenseIdentity?
    private let providerHealthCache = BELProviderHealthCache()

    /// Public anon key, the same one the landing page ships. Overridable from .env.
    private var anonKey: String {
        environment["BELAUNCHER_SUPABASE_ANON_KEY"] ?? BuildConfig.supabaseAnonKey
    }

    private var licenseClient: LicenseClient {
        LicenseClient(baseURL: LicenseClient.productionBaseURL, anonKey: anonKey)
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0-dev"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchStartedAt = .now
        environment = Env.load(paths: [
            (Store.defaultPath() as NSString).deletingLastPathComponent + "/.env",
            FileManager.default.currentDirectoryPath + "/.env",
        ])

        let store: Store
        do {
            store = try Store(path: Store.defaultPath())
        } catch {
            presentFatal(error)
            return
        }
        self.store = store
        installAppIntentObservers()
        // Before a single label is drawn. Reading it later means the first window renders in the
        // system language and then changes under the person, which looks like a bug even when the
        // final state is right.
        Loc.language = Language.resolve(stored: store.setting("interface_language"),
                                        systemPreferred: Locale.preferredLanguages)

        // Before anything draws. The very first screen a new user sees is the activation window,
        // and it is the one where the language matters most: somebody who cannot read the box they
        // are typing their licence key into does not get a second chance to change a setting.
        Loc.language = Language.resolve(stored: store.setting("ui_language"),
                                        systemPreferred: Locale.preferredLanguages)

        // Paid app: nothing else starts until this Mac is activated. An activated Mac never
        // waits on the network again.
        vault = try? Vault(root: Vault.defaultRoot())
        LicenseVault.use(store)
        license = LicenseVault.load(currentDeviceID: DeviceIdentity.id)
        guard license != nil else {
            presentActivation()
            return
        }
        revalidateLicenseIfDue()

        store.seedIfEmpty()
        store.ensureQuickCommands()
        finishLaunch(store: store)
    }

    private func installAppIntentObservers() {
        #if canImport(AppIntents)
        let center = NotificationCenter.default
        appIntentObservers = [
            center.addObserver(forName: BELAppIntentNotification.runCommand, object: nil,
                               queue: .main) { [weak self] note in
                let command = note.userInfo?[BELAppIntentUserInfo.command] as? String ?? ""
                Task { @MainActor in self?.primeLauncher(with: command) }
            },
            center.addObserver(forName: BELAppIntentNotification.openBrain, object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in self?.openGraph() }
            },
            center.addObserver(forName: BELAppIntentNotification.showClipboard, object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in self?.togglePanel(mode: .clipboard) }
            },
            center.addObserver(forName: BELAppIntentNotification.openSettings, object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in self?.openSettings() }
            },
            center.addObserver(forName: BELAppIntentNotification.recordVoice, object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in self?.audioCapture?.toggleVoiceNote() }
            },
            center.addObserver(forName: BELAppIntentNotification.dictate, object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in self?.audioCapture?.toggleDictation() }
            },
            center.addObserver(forName: BELAppIntentNotification.readScreen, object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in self?.readScreenAndOffer() }
            },
            center.addObserver(forName: BELAppIntentNotification.quickNote, object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in self?.openQuickNoteEditor() }
            },
            center.addObserver(forName: BELAppIntentNotification.recordCall, object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in self?.callCapture?.toggle() }
            },
            center.addObserver(forName: BELAppIntentNotification.searchBrain, object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in self?.primeLauncher(with: "") }
            },
            center.addObserver(forName: BELAppIntentNotification.upcomingMeetings, object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in self?.primeLauncher(with: "upcoming meetings") }
            },
            center.addObserver(forName: BELAppIntentNotification.focus, object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in self?.primeLauncher(with: "focus") }
            },
            center.addObserver(forName: BELAppIntentNotification.prepareMeeting, object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in self?.primeLauncher(with: "prepare meeting") }
            },
            center.addObserver(forName: BELAppIntentNotification.openNotes, object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.openGraph()
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: BELBrainNavigationNotification.notes,
                                                        object: nil)
                    }
                }
            },
            center.addObserver(forName: BELAppIntentNotification.openGraph, object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in self?.openGraph() }
            },
            center.addObserver(forName: BELAppIntentNotification.transcribeLastVoice, object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.openGraph()
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: BELBrainNavigationNotification.notes,
                                                        object: nil)
                    }
                }
            },
            center.addObserver(forName: BELAppIntentNotification.openLauncher, object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in self?.togglePanel(mode: .all) }
            },
        ]
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handleDeepLink(url) }
    }

    private func handleDeepLink(_ url: URL) {
        guard let actionID = BELAppIntentCatalog.actionID(from: url),
              let definition = BELAppIntentCatalog.definition(id: actionID) else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "q" })?.value
        let command = query.flatMap { $0.isEmpty ? nil : $0 } ?? definition.command
        guard !command.isEmpty else { return }
        primeLauncher(with: command)
    }

    private func finishLaunch(store: Store) {
        store.trimClips(
            retentionDays: store.setting("clipboard_retention_days", default: 30),
            maxItems: store.setting("clipboard_max_items", default: 500)
        )

        let model = LauncherModel(
            dataSource: { [weak self] in
                guard let self, let store = self.store else { return SearchInput() }
                let needs = LauncherInputNeeds(
                    query: self.model?.query ?? "",
                    mode: self.model?.mode ?? .all
                )
                let cacheKey = [
                    needs.mode == .clipboard ? "clipboard" : "all",
                    needs.needsPacks ? "packs" : "",
                    needs.needsNotes ? "notes" : "",
                    needs.needsProcesses ? "processes" : "",
                    needs.needsWorkspaces ? "workspaces" : "",
                    needs.needsWorkGraph ? "graph" : "",
                    needs.needsMemories ? "memories" : "",
                    needs.needsCalendar ? "calendar" : "",
                    needs.needsTraits ? "traits" : ""
                ].joined(separator: "|")
                if let cached = self.launcherInputCache,
                   cached.key == cacheKey, cached.expires > .now {
                    return cached.input
                }
                let workNodes = needs.needsWorkGraph ? store.nodes(limit: 1_000) : []
                let workEdges = needs.needsWorkGraph ? store.workEdges(limit: 5_000) : []
                let input = SearchInput(
                    applications: self.appIndex.applications,
                    snippets: store.snippets(),
                    workflows: store.workflows(),
                    // The empty launchpad is a horizontal history surface: it must be able to
                    // reach every retained clip. LazyHStack keeps the cards cheap to render.
                    clips: store.clips(limit: 1_000),
                    flows: store.flows(),
                    applicationUses: store.applicationUses(),
                    aliases: store.aliases(),
                    shortcuts: self.shortcuts,
                    systemShortcuts: self.systemShortcuts,
                    memories: needs.needsMemories ? (self.vault?.current() ?? []) : [],
                    pendingCommits: needs.needsPendingCommits
                        ? (self.vault?.commits(state: .proposed) ?? []) : [],
                    events: needs.needsCalendar ? self.calendar.events : [],
                    packs: needs.needsPacks ? store.availablePacks() : [],
                    workNodes: workNodes,
                    workEdges: workEdges,
                    traits: needs.needsTraits ? store.traits() : [],
                    // Read only when the query asks for it: listing 400 processes on every
                    // keystroke would make typing anything else noticeably slower.
                    processes: needs.needsProcesses ? SystemUtilities.processes() : [],
                    workspaces: needs.needsWorkspaces ? store.workspaces() : [],
                    notes: needs.needsNotes ? QuickNote.records(inVaultAt: Vault.defaultRoot()) : []
                )
                self.launcherInputCache = (cacheKey, input, Date.now.addingTimeInterval(2))
                return input
            },
            fileInfo: { path in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return [] }
                var items: [ResultDetail.Item] = []
                if let size = attributes[.size] as? Int {
                    items.append(.init(label: L("Size"), value: ByteCountFormatter.string(
                        fromByteCount: Int64(size), countStyle: .file)))
                }
                if let modified = attributes[.modificationDate] as? Date {
                    items.append(.init(label: "Modificado",
                                       value: modified.formatted(date: .abbreviated, time: .shortened)))
                }
                return items
            },
            onLaunch: { [weak self] path in self?.store?.recordLaunch(path: path) },
            onPin: { [weak self] pinned, id in
                self?.store?.setPinned(pinned, clip: id)
                self?.launcherInputCache = nil
            },
            onDelete: { [weak self] kind, id in
                guard let store = self?.store else { return }
                self?.launcherInputCache = nil
                switch kind {
                case .clipboard: store.deleteClip(id: id)
                case .snippet: store.deleteSnippet(id: id)
                case .workflow: store.deleteWorkflow(id: id)
                case .flow: store.deleteFlow(id: id)
                default: break
                }
            },
            expander: {
                SnippetExpander(
                    clipboard: { NSPasteboard.general.string(forType: .string) },
                    secret: { Keychain.get($0) },
                    uuid: { UUID().uuidString },
                    now: .now
                )
            },
            recordUse: { [weak self] kind, id in
                self?.store?.recordUse(kind: kind, id: id)
                self?.launcherInputCache = nil
            },
            perform: { [weak self] action in self?.perform(action) }
        )
        model.onMissionDraftChanged = { [weak self] draft in
            guard let store = self?.store else { return }
            if let draft {
                store.saveActionDraft(ActionDraftSnapshot(mission: draft))
            } else {
                store.clearActionDrafts()
            }
        }
        if let draft = store.actionDrafts().first {
            model.restoreMissionDraft(draft.mission)
        }
        self.model = model

        let panel = CommandPanel(
            model: model,
            openSettings: { [weak self] in self?.openSettings() },
            newNote: { [weak self] in self?.openQuickNoteEditor() },
            recordVoice: { [weak self] in self?.audioCapture?.toggleVoiceNote() },
            dictate: { [weak self] in self?.audioCapture?.toggleDictation() })
        self.panel = panel

        // The agent runner owns the tray and everything that runs unattended.
        agentRunner = AgentRunner(
            store: store,
            ask: { [weak self] prompt, sensitivity in
                guard let self else { throw IntelligenceError.noProviderConfigured }
                return try await self.askModel(prompt, sensitivity: sensitivity)
            },
            perform: { [weak self] action in self?.perform(action) },
            context: { [weak self] source in await self?.gather(source) ?? nil },
            granted: { [weak self] permission in self?.isGranted(permission) ?? false }
        )

        installEditMenu()
        installServices()
        installStatusItem()
        audioCapture = AudioCaptureController(
            notify: { [weak self] message in self?.setAudioStatus(message) },
            onSaved: { [weak self] in self?.refreshBrain(force: true) },
            targetApplication: { [weak self] in
                let ownPID = ProcessInfo.processInfo.processIdentifier
                if let front = NSWorkspace.shared.frontmostApplication,
                   front.processIdentifier != ownPID {
                    return front
                }
                return self?.appBeforePanel
            })
        if let audioCapture {
            capturePanel = CaptureStatusPanel(
                controller: audioCapture,
                openBrain: { [weak self] in self?.openGraph() },
                newNote: { [weak self] in self?.openQuickNoteEditor() })
        }
        callCapture = CallCaptureController(
            notify: { [weak self] message in self?.setCallStatus(message) },
            onCompleted: { [weak self] title, transcript in
                self?.openCallReview(title: title, transcript: transcript)
            },
            onSaved: { [weak self] in self?.refreshBrain(force: true) },
            source: CallAudioSource(rawValue: store.setting("call_audio_source") ?? "") ?? .automatic)
        callCapture?.onSuggestionChange = { [weak self] in self?.refreshCallSuggestion() }
        refreshCallSuggestion()
        AudioCaptureController.pruneRecordings()
        announceUpdateIfAny()
        installKeyMonitor()
        registerHotKey(named: store.setting("hotkey") ?? HotKey.Combo.all[0].label)
        recordLauncherReady(store: store)
        if CommandLine.arguments.contains("--benchmark-startup") {
            let value = store.setting("startup_launcher_ready_ms") ?? "?"
            FileHandle.standardOutput.write(Data("launcher-ready-ms=\(value)\n".utf8))
            exit(0)
        }

        Sounds.enabled = store.setting("sounds_enabled", default: true)
        Sounds.chromeEnabled = store.setting("sounds_chrome", default: false)

        let watcher = ClipboardWatcher(store: store)
        clipboard = watcher
        if store.setting("clipboard_enabled", default: true) { watcher.start() }

        installApplicationActivityCapture()
        indexApplications()
        captureCalendarIntoGraph()
        startBrain()
        startCorpus(store: store)
        scheduleBoundedMaintenance(store: store)
        // Developer/runtime inspection only. The normal menu-bar launch remains unchanged, but
        // a deterministic entry point lets visual QA inspect the same Brain window without
        // relying on Accessibility to discover a status-item menu.
        if CommandLine.arguments.contains("--open-brain") {
            DispatchQueue.main.async { [weak self] in self?.openGraph() }
        }
        openWithLaunchQueryIfAny()
        showWelcomeOnFirstRun()
        offerBrainSetupIfNeeded()
    }

    /// Records the first usable boundary only. It intentionally runs before Brain, corpus and
    /// model startup so a large vault cannot hide a slow launcher behind one aggregate number.
    private func recordLauncherReady(store: Store) {
        let milliseconds = Int(Date().timeIntervalSince(launchStartedAt) * 1_000)
        store.setSetting("startup_launcher_ready_ms", String(max(0, milliseconds)))
    }

    private func scheduleBoundedMaintenance(store: Store) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            _ = store.purgeSecrets(limit: 500)
        }
    }

    // MARK: - Operational memory

    /// Starts the corpus pass, and asks about capture the first time.
    ///
    /// Nothing here touches the launch path: the runner sleeps ninety seconds before its first pass
    /// and does its reading off the main actor, so the hot key is live long before any of this
    /// costs anything.
    private func startCorpus(store: Store) {
        let runner = CorpusRunner(store: store, brain: brain) { [weak self] system, user in
            guard let self else { throw IntelligenceError.noProviderConfigured }
            // Confidential: the day's episodes are the most personal thing the app holds, so this
            // pass is pinned to a local model and never routes to a hosted one.
            return try await self.askModel(user, sensitivity: .confidential, system: system)
        }
        corpusRunner = runner
        runner.start()
        askAboutCaptureIfNeeded()
    }

    private func syncCorpusSource(_ source: String) async -> CorpusRunner.RunResult {
        guard let corpusRunner else { return .failed(L("The capture service is not available.")) }
        while corpusRunner.isRunning {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if source == "all" {
            return await corpusRunner.runOnce(ignoringPowerPolicy: true)
        } else {
            return await corpusRunner.runOnce(source: source, ignoringPowerPolicy: true)
        }
    }

    private func reviewInterruptedAction(_ id: String) {
        guard let store, let snapshot = store.actionRuns(limit: 100).first(where: { $0.id == id }),
              let mission = snapshot.missionForReview() else { return }
        model?.restoreMissionDraft(mission)
        panel?.present()
    }

    /// Asks, once, whether the brain may watch what happens on this Mac.
    ///
    /// `graph_enabled` has been `false` since the app shipped and it shows: a real database from
    /// somebody who has used BeLauncher for months holds zero nodes. The feature was not rejected,
    /// it was never offered — the switch lives in Ajustes under a name that does not explain what
    /// it does, so nobody ever found it.
    ///
    /// The fix is not to turn it on quietly. Capture that a person did not agree to is the one bug
    /// that cannot be apologised for afterwards, and a memory product that starts by helping itself
    /// has nothing left to promise. So it is asked, in plain words, with the list of what would be
    /// read and the controls for stopping it on the same screen — and a no is remembered as an
    /// answer rather than as a question that was not read yet.
    private func askAboutCaptureIfNeeded() {
        guard let store else { return }
        guard store.setting("capture_asked", default: false) == false else { return }
        guard store.setting("welcomed", default: false) == true else { return }

        Task { @MainActor [weak self] in
            // Behind the welcome window and the model offer. Three windows competing for a first
            // run is how all three get dismissed unread.
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.welcomeWindow == nil, self.consentWindow == nil else { return }
            guard self.store?.setting("capture_asked", default: false) == false else { return }
            self.presentCaptureConsent()
        }
    }

    private func presentCaptureConsent() {
        // Marked as asked before the window appears, not in the callback: closing it from the title
        // bar never reaches the callback, and a question that reappears every morning is one that
        // gets dismissed unread. Silence stays a no, which is the safe direction for this switch.
        store?.setSetting("capture_asked", true)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = L("Working memory")
        window.contentViewController = NSHostingController(rootView: CaptureConsentView(
            excluded: store?.excludedFromCapture().count ?? 0,
            onDecide: { [weak self] enabled in
                guard let self else { return }
                self.store?.setSetting("graph_enabled", enabled)
                self.settingsModel?.graphEnabled = enabled
                self.consentWindow?.close()
                self.consentWindow = nil
                if enabled { self.captureCalendarIntoGraph() }
            }
        ))
        window.isReleasedWhenClosed = false
        place(window)
        consentWindow = window

        panel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Connects the searchable brain without making the hotkey pay for maintenance work.
    ///
    /// A real brain can hold tens of gigabytes of derived data. Startup must not count it, rebuild
    /// it or walk it before the command bar can appear. Explicit rebuilds still live in Settings;
    /// this path only gives already-indexed passages a tiny, delayed vector catch-up.
    private func startBrain() {
        guard let store else { return }
        // Schema creation is cheap; repairing legacy titles is a full-table maintenance sweep.
        // Never put that sweep in the command bar's startup path.
        try? store.migrateSemanticIndex(repairOversizedTitles: false)
        let brain = BrainSearch(store: store)
        self.brain = brain
        model?.brain = brain

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await brain.detectEngine()
            guard self.brain === brain else { return }
            _ = try? await brain.embedEverything(maximumBatches: 1)
        }
    }

    /// Re-cuts everything that changed. Cheap: unchanged sources keep their passages and their
    /// vectors, so this is a no-op for anything untouched since the last pass.
    private func reindexBrain() {
        guard let brain, let store else { return }
        brain.index(
            memories: vault?.objects() ?? [],
            nodes: store.nodes(limit: 2_000),
            clips: store.clips(limit: 500),
            notes: QuickNote.records(inVaultAt: Vault.defaultRoot())
        )
    }

    /// Called after anything is added to the brain, so a memory saved thirty seconds ago is
    /// findable now rather than after the next launch.
    private func refreshBrain(force: Bool = false) {
        // Copying happens dozens of times an hour; re-embedding on each one would keep a model
        // busy for no gain, since nobody searches for something the same second they copied it.
        if !force, let last = lastBrainRefresh, Date().timeIntervalSince(last) < 60 { return }
        lastBrainRefresh = Date()
        reindexBrain()
        Task { @MainActor [weak self] in
            _ = try? await self?.brain?.embedEverything(maximumBatches: force ? 4 : 2)
        }
    }

    /// `open -a BeLauncher --args --query "algo"` opens the window with that text already typed.
    /// A development affordance: scripted keystrokes do not reach a non-activating panel, so
    /// without this the UI can only be checked by hand.
    private func openWithLaunchQueryIfAny() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--query"), flag + 1 < arguments.count else { return }
        let text = arguments[flag + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, let model = self.model else { return }
            self.togglePanel(mode: .all)
            model.query = text
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.invalidate()
        clipboardHotKey?.invalidate()
        screenHotKey?.invalidate()
        voiceNoteHotKey?.invalidate()
        dictationHotKey?.invalidate()
        callHotKey?.invalidate()
        clipboard?.stop()
        if let observer = applicationActivityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: - Licensing

    private func presentActivation() {
        let model = ActivationModel(client: licenseClient) { [weak self] identity in
            guard let self else { return }
            self.license = identity
            self.activationWindow?.close()
            self.activationWindow = nil
            self.activationModel = nil
            self.startAfterActivation()
        }
        activationModel = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 430),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "BeLauncher"
        window.contentViewController = NSHostingController(rootView: ActivationView(model: model))
        window.isReleasedWhenClosed = false
        place(window)
        activationWindow = window

        NSApp.setActivationPolicy(.regular)   // the activation window needs to be reachable
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Runs the normal launch path once a license exists.
    private func startAfterActivation() {
        NSApp.setActivationPolicy(.accessory)
        guard let store else { return }
        store.seedIfEmpty()
        store.ensureQuickCommands()
        finishLaunch(store: store)
    }

    /// A monthly courtesy check. It can only ever *confirm*; a failure never locks the app.
    private func revalidateLicenseIfDue() {
        guard let license, LicenseGate.shouldRevalidate(lastCheck: license.lastCheck) else { return }
        let client = licenseClient
        Task { @MainActor in
            let outcome = await client.activate(
                email: license.email, key: license.key,
                deviceID: license.deviceID, deviceName: DeviceIdentity.name
            )
            guard case .activated = outcome else { return }   // offline or hiccup: leave it be
            var refreshed = license
            refreshed.lastCheck = .now
            try? LicenseVault.save(refreshed)
            self.license = refreshed
        }
    }

    // MARK: - Wiring

    private func indexApplications() {
        model?.isIndexing = true
        Task { @MainActor in
            let index = await Task.detached(priority: .userInitiated) { AppIndex.scan() }.value
            appIndex = index
            shortcuts = await Task.detached(priority: .utility) { ShortcutIndex.scan() }.value
            systemShortcuts = Shortcuts.available()
            calendar.refresh()
            model?.isIndexing = false
        }
    }

    /// Records only the frontmost app changing. This is the low-risk global context source: it
    /// needs no Accessibility permission and never reads a window, document or keystroke. The
    /// relevance pass later decides whether repeated activity is worth indexing.
    private func installApplicationActivityCapture() {
        guard applicationActivityObserver == nil else { return }
        applicationActivityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let bundle = app.bundleIdentifier,
                  let path = app.bundleURL?.path else { return }
            Task { @MainActor in
                self.rememberApplicationActivity(name: app.localizedName ?? bundle,
                                                  bundleIdentifier: bundle, path: path)
            }
        }
    }

    private func rememberApplicationActivity(name: String, bundleIdentifier: String, path: String) {
        guard let store,
              store.setting("graph_enabled", default: false),
              store.privacyState.isCapturing(),
              !store.excludedFromCapture().contains(bundleIdentifier.lowercased()) else { return }
        remember(Capture.application(named: name, path: path))
    }

    /// Puts BeLauncher in the right-click → Servicios menu of every app.
    private func installServices() {
        let provider = ServiceProvider()
        provider.runVerb = { [weak self] id, text in
            guard let self else { return }
            self.togglePanel(mode: .all)
            self.runAIVerb(id: id, text: text)
        }
        provider.writeNote = { [weak self] text in self?.perform(.writeNote(text: text)) }
        provider.remember = { [weak self] text, source in
            self?.perform(.remember(text: text, source: source))
        }
        serviceProvider = provider
        ServiceProvider.install(provider)
    }

    /// Gives the app the Edit menu it never had, which is what makes ⌘V work.
    ///
    /// A launcher you cannot paste into is not a launcher. macOS routes ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z
    /// through the main menu — the shortcuts are not built into text fields, they are menu items
    /// whose action travels the responder chain. This app never built a main menu because it lives
    /// in the menu bar with no windows of its own, so those keys had nowhere to go and did
    /// nothing, in the search field and in every text field in Settings.
    ///
    /// The menu is never shown, since the app is an accessory. It exists purely so the keys work.
    private func installEditMenu() {
        let edit = NSMenu(title: L("Edit"))
        let items: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Deshacer", Selector(("undo:")), "z", .command),
            ("Rehacer", Selector(("redo:")), "z", [.command, .shift]),
            ("Cortar", #selector(NSText.cut(_:)), "x", .command),
            (L("Copy"), #selector(NSText.copy(_:)), "c", .command),
            ("Pegar", #selector(NSText.paste(_:)), "v", .command),
            // Pasting a styled quote into a search field should paste the words, not the styling.
            (L("Paste without formatting"), Selector(("pasteAsPlainText:")), "v", [.command, .shift, .option]),
            (L("Select all"), #selector(NSText.selectAll(_:)), "a", .command),
        ]
        for (title, action, key, modifiers) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            edit.addItem(item)
        }

        let root = NSMenu()
        let editItem = NSMenuItem()
        editItem.submenu = edit
        root.addItem(editItem)
        NSApp.mainMenu = root
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = BeLauncherMark.menuBarImage()
            ?? NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "BeLauncher")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let open = NSMenuItem(title: L("Open BeLauncher"), action: #selector(togglePanelFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let voice = NSMenuItem(title: L("Record voice note"), action: #selector(toggleVoiceNote), keyEquivalent: "")
        voice.target = self
        menu.addItem(voice)
        audioItem = voice
        let dictate = NSMenuItem(title: L("Dictate to current app"), action: #selector(toggleDictation), keyEquivalent: "")
        dictate.target = self
        menu.addItem(dictate)
        let call = NSMenuItem(title: L("Record call"), action: #selector(toggleCallRecording), keyEquivalent: "")
        call.target = self
        menu.addItem(call)
        callItem = call
        let suggestion = NSMenuItem(title: "", action: #selector(toggleCallRecording), keyEquivalent: "")
        suggestion.target = self
        suggestion.isHidden = true
        menu.addItem(suggestion)
        callSuggestionItem = suggestion

        // Hidden until there is something to say. An update the person has to go looking for in
        // Settings is not an announcement.
        let update = NSMenuItem(title: "", action: #selector(openSettings), keyEquivalent: "")
        update.target = self
        update.isHidden = true
        menu.addItem(update)
        updateItem = update

        menu.addItem(.separator())
        // Visible state, and one click to end it. An assertion you cannot see is how a laptop
        // ends up awake in a bag all night.
        let awake = NSMenuItem(title: "", action: #selector(toggleAwake), keyEquivalent: "")
        awake.target = self
        awake.isHidden = true
        menu.addItem(awake)
        awakeItem = awake

        // The brain has to be reachable from the menu, not only from a command somebody has to
        // know exists. It was reachable from nowhere at all until this line.
        let brain = NSMenuItem(title: L("Your brain…"), action: #selector(openGraph), keyEquivalent: "")
        brain.target = self
        menu.addItem(brain)

        let guide = NSMenuItem(title: L("Quick guide"), action: #selector(openWelcome), keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)
        let settings = NSMenuItem(title: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let reindex = NSMenuItem(title: L("Look for apps again"), action: #selector(rescan), keyEquivalent: "")
        reindex.target = self
        menu.addItem(reindex)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quit BeLauncher"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleVoiceNote() {
        audioCapture?.toggleVoiceNote()
    }

    @objc private func toggleDictation() {
        audioCapture?.toggleDictation()
    }

    @objc private func toggleCallRecording() {
        callCapture?.toggle()
    }

    private func setAudioStatus(_ message: String) {
        audioItem?.title = audioCapture?.isRecording == true
            ? L("Stop voice note") : L("Record voice note")
        statusItem?.button?.toolTip = message
        capturePanel?.present()
        if audioCapture?.isRecording != true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard self?.audioCapture?.isRecording != true else { return }
                self?.capturePanel?.orderOut(nil)
            }
        }
    }

    private func setCallStatus(_ message: String) {
        callItem?.title = callCapture?.isRecording == true
            ? L("Stop call recording") : L("Record call")
        statusItem?.button?.toolTip = message
    }

    private func refreshCallSuggestion() {
        guard let item = callSuggestionItem, let capture = callCapture,
              !capture.isRecording, let app = capture.suggestedAppName else {
            callSuggestionItem?.isHidden = true
            return
        }
        item.isHidden = false
        item.title = capture.likelyInCall
            ? L("Possible call in %@ — record", app)
            : L("%@ is open — record call", app)
    }

    private func openCallReview(title: String, transcript: String) {
        let review = CallReviewModel(title: title, transcript: transcript) { [weak self] prompt in
            guard let self else { throw IntelligenceError.noProviderConfigured }
            return try await self.askModel(prompt, sensitivity: .confidential)
        } save: { [weak self] title, analysis in
            guard let self else { return }
            let noteTitle = "\(title) - actions"
            let vault = try Vault(root: Vault.defaultRoot())
            _ = try vault.saveEvidence(title: noteTitle, text: analysis)
            self.refreshBrain(force: true)
        }
        callReviewModel = review
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 650),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentViewController = NSHostingController(rootView: CallReviewView(model: review))
        window.isReleasedWhenClosed = false
        place(window)
        callReviewWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleAwake() {
        SystemUtilities.stopStayingAwake()
        refreshAwakeItem()
    }

    private func refreshAwakeItem() {
        guard let awakeItem else { return }
        awakeItem.isHidden = !SystemUtilities.isAwake
        awakeItem.title = SystemUtilities.isAwake
            ? StayAwake.remaining(until: SystemUtilities.awakeUntil) + L("· turn off")
            : ""
    }

    /// Looks for a new version once, quietly, and only if the person turned that on.
    ///
    /// It never interrupts: no dialog, no notification, no badge on the icon while you are working.
    /// The menu bar grows one line, which is there when you next look and invisible when you do not.
    private func announceUpdateIfAny() {
        guard store?.setting("update_check_enabled", default: false) == true else { return }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0.0.0"
        Task { @MainActor in
            let feed = environment["BELAUNCHER_UPDATE_FEED_URL"] ?? UpdateCheck.defaultFeedURL
            guard case .available(let release) = await UpdateCheck.run(feedURL: feed,
                                                                      currentVersion: current)
            else { return }
            updateItem?.title = "Actualizar a \(release.version)…"
            updateItem?.isHidden = false
            // The menu bar and Settings have to agree. Announcing an update in one place and then
            // making the person press "Buscar ahora" in the other to see the button is the same
            // half-wired thing as not announcing it at all.
            pendingRelease = release
            settingsModel?.availableUpdate = release
            settingsModel?.updateStatus = L("There is a new version: %@", release.version)
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow, let model = self.model else { return event }

            let command = event.modifierFlags.contains(.command)
            let shift = event.modifierFlags.contains(.shift)
            let option = event.modifierFlags.contains(.option)
            let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

            if command, characters == "," {
                self.openSettings()
                return nil
            }
            // ⌘K opens the action panel, the shortcut people already have in their fingers.
            if command, characters == "k" {
                model.handle(.actionPanel)
                return nil
            }

            // ⌃⌘0..9 grabs a clipboard card without moving the selection at all — the fastest
            // route there is, and the reason the cards carry a number.
            if command, event.modifierFlags.contains(.control), model.mode == .clipboard,
               let digit = Int(characters), model.results.indices.contains(digit) {
                model.select(digit)
                model.runSelected()
                return nil
            }

            switch event.keyCode {
            // In the carousel the cards run left to right, so the arrows that move along them are
            // the horizontal ones. Up and down keep working: muscle memory is not worth breaking
            // to make a point about layout.
            case 124 where model.mode == .clipboard: model.handle(.down); return nil   // arrow right
            case 123 where model.mode == .clipboard: model.handle(.up); return nil     // arrow left
            case 125: model.handle(.down); return nil     // arrow down
            case 126: model.handle(.up); return nil       // arrow up
            case 36, 76:                                   // return / enter
                if command {
                    model.handle(.secondaryAction)
                } else {
                    model.handle(.enter)
                }
                return nil
            case 53: model.handle(.escape); return nil    // escape
            case 48:                                       // tab
                if model.isActionPanelOpen { return event }
                return model.handle(.tab) ? nil : event
            default:
                break
            }

            // Any other shortcut declared by an action of the selected result.
            if command || option,
               let result = model.selected,
               let action = ActionRegistry.actions(for: result).first(where: {
                   $0.shortcut?.matches(characters: characters, keyCode: event.keyCode,
                                        command: command, shift: shift, option: option) == true
               }) {
                model.run(action)
                return nil
            }

            return event
        }
    }

    private func registerHotKey(named label: String) {
        hotKey?.invalidate()
        hotKey = HotKey(combo: .named(label)) { [weak self] in self?.togglePanel(mode: .all) }
        // ⌥C opens straight into clipboard history.
        clipboardHotKey?.invalidate()
        screenHotKey?.invalidate()
        voiceNoteHotKey?.invalidate()
        dictationHotKey?.invalidate()
        callHotKey?.invalidate()
        screenHotKey = HotKey(combo: .screenAction) { [weak self] in
            self?.readScreenAndOffer()
        }
        voiceNoteHotKey = HotKey(combo: .voiceNote) { [weak self] in
            self?.audioCapture?.toggleVoiceNote()
        }
        dictationHotKey = HotKey(combo: .dictation) { [weak self] in
            self?.audioCapture?.toggleDictation()
        }
        callHotKey = HotKey(combo: .callRecording) { [weak self] in
            self?.callCapture?.toggle()
        }
        clipboardHotKey = HotKey(combo: .clipboardHistory) { [weak self] in
            self?.togglePanel(mode: .clipboard)
        }
        if hotKey == nil {
            // Another app already owns this shortcut — say so instead of failing silently.
            let alert = NSAlert()
            alert.messageText = "BeLauncher could not register \(label)"
            alert.informativeText = "Another app is already using that shortcut. Pick a different one in Settings."
            alert.runModal()
        }
    }

    // MARK: - Actions

    @objc func togglePanelFromMenu() { togglePanel(mode: .all) }

    func togglePanel(mode: LauncherModel.Mode) {
        guard let panel, let model else { return }
        if panel.isVisible, model.mode == mode {
            panel.orderOut(nil)
        } else {
            // Remembered before the panel takes focus: everything that acts on "the window you
            // were using" needs to know who that was, and a moment later the answer is us.
            let ours = ProcessInfo.processInfo.processIdentifier
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != ours {
                appBeforePanel = front
            }
            model.activate(mode: mode)
            launcherInputCache = nil
            panel.present()
        }
    }

    func primeLauncher(with text: String) {
        guard let panel, let model else { return }
        model.activate(mode: .all)
        model.query = text
        panel.present()
    }

    @objc private func rescan() { indexApplications() }

    @objc func openSettings() {
        guard let store else { return }
        if let window = settingsWindow {
            settingsModel?.refreshNotificationPermission()
            settingsModel?.refreshBrainState()
            settingsModel?.scanLocalModels()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let settingsModel = SettingsModel(
            store: store,
            appVersion: appVersion,
            updateFeedURL: environment["BELAUNCHER_UPDATE_FEED_URL"] ?? UpdateCheck.defaultFeedURL
        )
        settingsModel.license = license
        settingsModel.licenseClient = licenseClient
        // Carried over from the launch check, so the button is there the moment Settings opens.
        settingsModel.availableUpdate = pendingRelease
        if let pending = pendingRelease {
            settingsModel.updateStatus = L("There is a new version: %@", pending.version)
        }
        settingsModel.calendar = calendar
        settingsModel.onRequestNotifications = { [weak self] in
            await self?.requestNotifications() ?? false
        }
        settingsModel.onHotKeyChange = { [weak self] label in self?.registerHotKey(named: label) }
        settingsModel.onCallAudioSourceChange = { [weak self] source in self?.callCapture?.source = source }
        settingsModel.onSourceSync = { [weak self] source in
            guard let self else { return .failed(L("The capture service is not available.")) }
            return await self.syncCorpusSource(source)
        }
        settingsModel.onReviewInterrupted = { [weak self] id in self?.reviewInterruptedAction(id) }
        settingsModel.onClipboardToggle = { [weak self] enabled in
            enabled ? self?.clipboard?.start() : self?.clipboard?.stop()
        }
        self.settingsModel = settingsModel

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = L("BeLauncher settings")
        window.contentViewController = NSHostingController(rootView: SettingsView(model: settingsModel))
        window.isReleasedWhenClosed = false
        place(window)
        settingsWindow = window

        panel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Opens the brain: what it knows about you, drawn, and correctable.
    ///
    /// Wired here because it was not wired anywhere. Nine hundred lines of graph existed and no
    /// path in the binary reached them, so every correction it can make, every merge it can undo
    /// and every hour it can forget were unreachable — the feature was written, tested and
    /// invisible. An audit found it with one grep.
    @objc func openGraph() {
        guard let store, let corpusRunner else { return }
        if let window = graphWindow {
            // The graph can be opened while the corpus pass is still filling the store. Refresh
            // the retained model when the person returns instead of preserving that first empty
            // snapshot forever.
            graphModel?.load()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        // The same root the corpus runner writes to. A different one silently opens the loop
        // again: corrections would be written where nothing reads them, and nothing would fail.
        let folder = try? CorpusFolder(root: CorpusFolder.defaultRoot())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = L("Your brain")
        let model = GraphModel(store: store, corpus: folder)
        graphModel = model
        model.onRead = { [weak self] id in self?.openCorpusReader(selecting: id) }
        model.onPrimeLauncher = { [weak self] text in self?.primeLauncher(with: text) }
        window.contentViewController = NSHostingController(rootView: GraphView(
            model: model,
            coordinator: commandCoordinator,
            corpusRunner: corpusRunner,
            askBrain: { [weak self] question, context in
                guard let self else { throw IntelligenceError.noProviderConfigured }
                return try await self.askBrain(question, context: context)
            },
            importText: { [weak self] text, title in self?.importBrainText(text, title: title) },
            importFile: { [weak self] url in self?.importBrainFile(url) },
            retryTranscription: { [weak self] record in self?.retryTranscription(record) },
            saveNote: { [weak self] text in self?.perform(.writeNote(text: text)) },
            runMission: { [weak self] mission, completion in
                self?.runMission(mission, completion: completion)
            },
            cancelMission: { [weak self] mission in self?.cancelMission(mission.id) },
            runIntent: { [weak self] text in self?.primeLauncher(with: text) },
            openCitation: { [weak self] citation in self?.openBrainCitation(citation) }))
        window.isReleasedWhenClosed = false
        place(window)
        graphWindow = window

        panel?.orderOut(nil)
        if CommandLine.arguments.contains("--open-brain") {
            // A deterministic QA launch must be visible even when the process was started by
            // `open` behind another app. Normal menu-bar launches keep the accessory policy.
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Reads the corpus as what it is on disk: Markdown files the person owns.
    func askBrain(_ question: String, context: BrainConversationContext? = nil) async throws -> BrainAnswer {
        guard let brain else { throw IntelligenceError.noProviderConfigured }
        let result = await brain.search(question, limit: 8)
        let usableContext = context.flatMap { value in
            value.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }

        // A selected document is a first-class source. Semantic retrieval may miss a short
        // note or a question that refers to a heading, but that must not turn the visible
        // document context into decoration.
        if result.hits.isEmpty, let usableContext {
            let document = Retriever.boundedText(usableContext.body,
                                                  tokenBudget: Retriever.defaultContextTokenBudget)
            let system = """
            Answer only from the selected local document below. If it does not contain the answer,
            say so in one sentence and stop. Do not use outside knowledge or invent details.
            Write in the same language as the question. Be direct.
            """
            let user = """
            Question: \(question)

            Selected document: \(usableContext.title)
            \(document)
            """
            let answer = try await askModel(user, system: system, brainContextLevel: .b3)
            return BrainAnswer(
                text: answer,
                sources: [BrainCitation(sourceID: usableContext.sourceID,
                                         title: usableContext.title,
                                         kind: L("Markdown you own"),
                                         canOpen: true)])
        }

        guard !result.hits.isEmpty else {
            return BrainAnswer(text: result.gap ?? L("The Brain has no evidence for that yet."), sources: [])
        }
        let context = Retriever.BeBrainContextProvider.retrieve(
            result: result, level: .b3, tokenBudget: Retriever.defaultContextTokenBudget)
        let prompt = Retriever.prompt(for: question, hits: context.hits)
        let contextualPrompt: String
        if let usableContext {
            let remaining = max(0, Retriever.defaultContextTokenBudget - context.estimatedTokens)
            let document = Retriever.boundedText(usableContext.body, tokenBudget: remaining)
            contextualPrompt = document.isEmpty
                ? prompt.user
                : prompt.user + "\n\nCurrent document context (use only to resolve references; cite retrieved passages):\n"
                    + document
        } else {
            contextualPrompt = prompt.user
        }
        let answer = try await askModel(contextualPrompt, system: prompt.system,
                                        brainContextLevel: .b3)
        let documents = (try? CorpusFolder(root: CorpusFolder.defaultRoot()))?.documents() ?? []
        var sources = context.hits.prefix(6).map { hit in
            BrainCitation(sourceID: hit.passage.source.id,
                          title: hit.passage.title,
                          kind: hit.passage.source.kind.label,
                          canOpen: documents.contains { $0.id == hit.passage.source.id })
        }
        if let usableContext, !sources.contains(where: { $0.sourceID == usableContext.sourceID }) {
            sources.insert(BrainCitation(sourceID: usableContext.sourceID,
                                         title: usableContext.title,
                                         kind: L("Markdown you own"),
                                         canOpen: true), at: 0)
        }
        return BrainAnswer(text: answer, sources: Array(sources))
    }

    /// Opens only evidence that has a real local document. A live Mail or Messages citation
    /// remains visible, but cannot send the person into an empty reader.
    private func openBrainCitation(_ citation: BrainCitation) {
        guard let corpus = try? CorpusFolder(root: CorpusFolder.defaultRoot()),
              corpus.documents().contains(where: { $0.id == citation.sourceID }) else { return }
        openCorpusReader(selecting: citation.sourceID)
    }

    func importBrainFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let text: String?
        if url.pathExtension.lowercased() == "pdf" {
            text = PDFDocument(url: url)?.string
        } else {
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            report(L("Import failed"), L("The file is not readable text.")); return
        }
        importBrainText(text, title: url.deletingPathExtension().lastPathComponent,
                        sourcePath: url.path)
    }

    func importBrainText(_ text: String, title: String, sourcePath: String? = nil) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L("Imported evidence") : title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let vault = try Vault(root: Vault.defaultRoot())
            _ = try vault.saveEvidence(title: cleanTitle, text: text, sourcePath: sourcePath)
            refreshBrain(force: true)
            report(L("Evidence imported"), cleanTitle)
        } catch {
            report(L("Import failed"), error.localizedDescription)
        }
    }

    @MainActor
    private func retryTranscription(_ record: QuickNote.Record) {
        guard record.state == .needsTranscription,
              let path = record.sourcePath,
              FileManager.default.fileExists(atPath: path) else {
            report(L("Retry unavailable"), L("The original audio is no longer at its saved path."))
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let transcript = try await VoiceProvider.transcribe(
                    fileAt: URL(fileURLWithPath: path), title: record.title)
                let vault = try Vault(root: Vault.defaultRoot())
                _ = try vault.saveEvidence(title: transcript.title,
                                           text: "Audio: \(path)\n\n\(transcript.text)",
                                           at: transcript.at, sourcePath: path)
                try? QuickNote.markReviewed(record)
                refreshBrain(force: true)
                report(L("Transcription saved"), record.title)
            } catch {
                report(L("Retry failed"), error.localizedDescription)
            }
        }
    }

    @objc func openCorpusReader(selecting id: String? = nil) {
        if let window = readerWindow {
            // Reusing the window must also reuse the user's current selection. Previously a
            // second node click only brought the old reader forward, which looked like an empty
            // or disconnected Brain even though the selected document existed.
            if let id, let readerModel {
                readerModel.reload()
                readerModel.select(id)
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let folder = try? CorpusFolder(root: CorpusFolder.defaultRoot()) else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = L("Your corpus")
        let model = CorpusReaderModel(folder: folder, selecting: id)
        readerModel = model
        window.contentViewController = NSHostingController(rootView: CorpusReaderView(model: model))
        window.isReleasedWhenClosed = false
        place(window)
        readerWindow = window

        panel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func openQuickNoteEditor(initialText: String = "") {
        if let window = quickNoteWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L("Quick note")
        window.contentViewController = NSHostingController(rootView: QuickNoteEditorView(
            initialText: initialText,
            save: { [weak self] text in self?.perform(.writeNote(text: text)) }))
        window.isReleasedWhenClosed = false
        place(window)
        quickNoteWindow = window
        panel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func createSnippet(from text: String) {
        guard let store else { return }
        let keyword = NSTextField(string: ";snippet")
        keyword.placeholderString = L("Trigger, e.g. ;firma")
        let title = NSTextField(string: L("New snippet"))
        title.placeholderString = L("Name")
        let fields = NSStackView(views: [keyword, title])
        fields.orientation = .vertical
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 62)
        let alert = NSAlert()
        alert.messageText = L("Create a snippet")
        alert.informativeText = L("Choose the trigger. The clipboard text is already loaded.")
        alert.accessoryView = fields
        alert.addButton(withTitle: L("Create"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trigger = keyword.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty, !name.isEmpty else {
            report(L("Snippet not created"), L("A trigger and a name are required.")); return
        }
        do {
            try store.addSnippet(keyword: trigger, title: name, body: text)
            report(L("Snippet created"), trigger)
        } catch {
            report(L("Snippet not created"), error.localizedDescription)
        }
    }

    /// Turns today's calendar into people, companies and meetings the graph can answer about.
    private func captureCalendarIntoGraph() {
        guard store?.setting("graph_enabled", default: false) == true else { return }
        Task { @MainActor in
            await calendar.requestAccessIfNeeded()
            calendar.refresh()
            rememberAll(Capture.events(from: calendar.events))
        }
    }

    /// What an agent is allowed to look at, gathered only when it says it needs it.
    func gather(_ source: AgentCommand.ContextSource) async -> AgentRun.Finding? {
        switch source {
        case .clipboard:
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
                return nil
            }
            return AgentRun.Finding(source: source, summary: String(text.prefix(4_000)))

        case .selection, .screen:
            let context = await ScreenCapture.read()
            guard !context.isEmpty else { return nil }
            return AgentRun.Finding(source: source, summary: String(context.text.prefix(4_000)))

        case .calendar:
            await calendar.requestAccessIfNeeded()
            calendar.refresh()
            let upcoming = calendar.events.prefix(6)
                .map { "\($0.title) · \($0.attendees.joined(separator: ", "))" }
            guard !upcoming.isEmpty else { return nil }
            return AgentRun.Finding(source: source, summary: upcoming.joined(separator: "\n"))

        case .brain:
            guard let vault else { return nil }
            let current = vault.current().prefix(12).map(\.statement)
            guard !current.isEmpty else { return nil }
            return AgentRun.Finding(source: source, summary: current.joined(separator: "\n"))

        case .workGraph:
            guard let store else { return nil }
            let recent = store.nodes(limit: 15).map { "\($0.kind.label): \($0.name)" }
            guard !recent.isEmpty else { return nil }
            return AgentRun.Finding(source: source, summary: recent.joined(separator: "\n"))

        case .files:
            guard let store else { return nil }
            let files = store.nodes(kind: .file, limit: 10).map(\.name)
            guard !files.isEmpty else { return nil }
            return AgentRun.Finding(source: source, summary: files.joined(separator: "\n"))

        case .none:
            return nil
        }
    }

    func isGranted(_ permission: Onboarding.Capability.Kind) -> Bool {
        switch permission {
        case .accessibility: Permissions.accessibilityGranted
        case .automation: Permissions.automationGranted()
        case .calendar: calendar.isAuthorised
        case .microphone: Permissions.microphoneGranted
        case .fullDiskAccess: Permissions.fullDiskAccessLikely
        case .screen: ScreenCapture.screenRecordingGranted
        case .notifications, .clipboard, .updates, .launchAtLogin: true
        }
    }

    // MARK: - Noticing what happens

    /// Records one thing that happened, for habits and for the work graph.
    ///
    /// Both are opt-in and both are separate switches: someone may want the graph that answers
    /// "what was I doing before the call" without wanting the app to propose new commands, and the
    /// reverse. One toggle for two different kinds of watching would be the lazy answer.
    private func note(signature: String, label: String) {
        store?.recordAction(signature: signature, label: label)
        offerRecipeIfAny()
    }

    /// Adds a node and its edges to the graph, if the person turned the graph on.
    private func remember(_ event: Capture.Event) {
        guard store?.setting("graph_enabled", default: false) == true else { return }
        store?.upsertNode(event.node)
        for link in event.links { store?.link(link) }
    }

    private func rememberAll(_ events: [Capture.Event]) {
        for event in events { remember(event) }
        // Things touched close together belong together. This is the edge "retoma lo que estaba
        // haciendo antes de la llamada" walks, and it only exists if somebody draws it.
        guard store?.setting("graph_enabled", default: false) == true, let store else { return }
        for edge in Capture.sessions(store.nodes(limit: 120)) { store.link(edge) }
    }

    /// A confirmed memory becomes a node, tied to the meeting it came out of when its source names
    /// one. That link is what lets "¿qué prometimos a Andrés?" find a commitment that never
    /// mentions him.
    private func rememberMemory(_ object: MemoryObject) {
        let meeting = calendar.events.first { object.source.localizedCaseInsensitiveContains($0.title) }
        remember(Capture.memory(object, fromMeeting: meeting?.title))
    }

    /// Offers to turn a repeated sequence into a command. Once per habit, never twice.
    private func offerRecipeIfAny() {
        guard let store, store.habitsEnabled else { return }
        let log = store.actionLog()
        guard let recipe = Autopilot.recipes(
            from: log, alreadyOffered: { store.recipeAlreadyOffered($0) }
        ).first else { return }

        let alert = NSAlert()
        alert.messageText = L("Shall I turn it into a command?")
        alert.informativeText = recipe.offer
            + L("\n\nIt gets kept as a flow called “%@”, which you can edit or delete whenever you want.",
                recipe.suggestedKeyword)
        alert.addButton(withTitle: L("Yes, make it"))
        alert.addButton(withTitle: L("No thanks"))
        let accepted = alert.runModal() == .alertFirstButtonReturn
        store.markRecipeOffered(recipe.id, accepted: accepted)
        guard accepted else { return }

        let flow = Autopilot.flow(from: recipe)
        do {
            try store.addFlow(keyword: flow.keyword, title: flow.title, steps: flow.steps)
            report(L("Done"), L("Type “%@” to run it.", flow.keyword))
        } catch {
            report(L("The command could not be made"), error.localizedDescription)
        }
    }

    // MARK: - Screen to action

    /// Reads what is in front of the person and offers the three sensible things to do with it.
    ///
    /// The offers come from what it recognised, not from a fixed menu: an error gets "explain" and
    /// "how do I fix it", an invoice gets "extract the fields" and "file it". Three, never ten —
    /// this appears over whatever someone is doing, and a long list at that moment costs more
    /// attention than doing it by hand would have.
    func readScreenAndOffer() {
        Task { @MainActor in
            let context = await ScreenCapture.read()
            guard ScreenReader.isWorthOffering(context) else {
                report(L("Select what you want first"),
                       L("Mark the text, the table or the error you want me to deal with and press ⌥⇧Space again. It used to read the whole screen and offer things about whatever happened to be in front of you, which was noise more often than help."))
                return
            }
            let subject = ScreenReader.subject(of: context)
            presentOffers(ScreenReader.offers(for: subject), subject: subject, context: context)
        }
    }

    private func presentOffers(_ offers: [ScreenReader.Offer], subject: ScreenReader.Subject,
                               context: ScreenContext) {
        let alert = NSAlert()
        alert.messageText = L("%1$@, from %2$@", subject.label, context.origin.label)
        alert.informativeText = String(context.text.prefix(240))
            + (context.text.count > 240 ? "…" : "")
        for offer in offers { alert.addButton(withTitle: offer.title) }
        alert.addButton(withTitle: L("Nothing"))

        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard offers.indices.contains(index) else { return }
        run(offers[index], on: context)
    }

    private func run(_ offer: ScreenReader.Offer, on context: ScreenContext) {
        switch offer.verb {
        case "open":
            if let url = URL(string: context.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                NSWorkspace.shared.open(url)
            }
        case "remember":
            rememberIntoVault(text: context.text, source: L("Seen in %@", context.application))
        case "search-web":
            let query = context.text.prefix(180)
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "https://www.google.com/search?q=\(query)") {
                NSWorkspace.shared.open(url)
            }
        default:
            // Verbs the app already has run as themselves; the rest carry their own instruction.
            if AIVerb.named(offer.verb) != nil {
                runAIVerb(id: offer.verb, text: context.text)
            } else if let instruction = ScreenReader.instruction(for: offer.verb) {
                runFreeformAI(title: offer.title, instruction: instruction, text: context.text)
            }
        }
    }

    /// Asks the model something the verb catalogue does not cover, showing it in the same pane.
    private func runFreeformAI(title: String, instruction: String, text: String) {
        guard let model else { return }
        model.aiWorking(title)
        togglePanel(mode: .all)
        aiTask?.cancel()
        aiTask = Task { @MainActor in
            do {
                let answer = try await askModel("\(instruction)\n\n---\n\(text)") { fragment in
                    Task { @MainActor in model.aiStreaming(verb: title, fragment: fragment) }
                }
                model.aiAnswered(verb: title, text: answer)
            } catch let error as IntelligenceError {
                model.aiFailed(error.description)
            } catch {
                model.aiFailed(error.localizedDescription)
            }
        }
    }

    // MARK: - The tray

    func openTray() {
        guard let runner = agentRunner else { return }
        if let window = trayWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.title = L("Missions")
        window.contentViewController = NSHostingController(rootView: MissionTrayView(runner: runner))
        window.isReleasedWhenClosed = false
        place(window)
        trayWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Canvas

    /// Opens a canvas for an outcome that is a set of pieces rather than one answer.
    ///
    /// It gets its own window rather than growing the launcher panel: the panel is a place you
    /// pass through, and this is a place you stay in for a few minutes.
    func openCanvas(template: String, brief: String) {
        guard let definition = CanvasTemplate.named(template), let store else { return }
        panel?.orderOut(nil)

        // Whatever the brain already knows about the subject goes in as context, so a proposal for
        // a client the company has history with does not start from nothing.
        let context = vault.map { vault in
            BrainQuery.relevant(brief, in: vault.current(), kinds: nil)
                .prefix(6)
                .map(\.statement)
                .joined(separator: "\n")
        } ?? ""

        let model = CanvasModel(
            definition: definition, brief: brief, context: context,
            run: { [weak self] prompt in
                guard let self else { throw IntelligenceError.noProviderConfigured }
                return try await self.askModel(prompt)
            },
            perform: { [weak self] action in self?.perform(action) },
            saveToBrain: { [weak self] canvas in self?.saveCanvas(canvas) },
            learn: { [weak self] before, after in
                self?.store?.observe(OperatingModel.observeEdit(before: before, after: after))
            }
        )
        canvasModel = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = definition.title
        window.contentViewController = NSHostingController(rootView: CanvasView(model: model))
        window.isReleasedWhenClosed = false
        place(window)
        canvasWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        _ = store
        model.fillAll()
    }

    private func saveCanvas(_ canvas: BeLauncherCore.Canvas) {
        do {
            let vault = try Vault(root: Vault.defaultRoot())
            _ = try vault.saveEvidence(title: canvas.title, text: canvas.render())
            refreshBrain(force: true)
            report(L("Canvas saved"), canvas.title)
        } catch {
            report(L("Canvas could not be saved"), error.localizedDescription)
        }
    }

    /// One question to whichever model is available, used by canvases and agents alike.
    ///
    /// Shared so there is exactly one place that decides which provider answers, which model it
    /// asks for, and what the person's own style adds to the prompt.
    func askModel(_ prompt: String, sensitivity: Sensitivity = .personal,
                  system override: String? = nil,
                  brainContextLevel: BELActionDefinition.BrainContextLevel = .b0,
                  onFragment: (@Sendable (String) -> Void)? = nil) async throws -> String {
        guard let store else { throw IntelligenceError.noProviderConfigured }
        let running = await LocalModels.installed()
        var models: [String: String] = [:]
        for installation in running {
            models[installation.providerID] = store.setting("ai_model_\(installation.providerID)")
                .flatMap { saved in installation.models.contains(saved) ? saved : nil }
                ?? installation.models[0]
        }
        let runningIDs = Set(running.map(\.providerID))
        let available = IntelligenceProvider.all.filter { provider in
            provider.isPrivate
                ? runningIDs.contains(provider.id)
                : (Keychain.get(provider.keychainAccount)?.isEmpty == false)
        }
        let router = ModelRouter(
            preferred: store.setting("ai_provider"),
            localOnlyFor: store.setting("ai_confidential_local", default: true) ? [.confidential] : []
        )
        let health = await providerHealthCache.snapshot(for: available, models: models)
        let providers = try router.providers(for: sensitivity, available: available, health: health,
                                             machine: MacCapabilityDetector.current(),
                                             routePolicy: brainContextLevel.requiresLocalExecution
                                                 ? .localOnly : nil)

        // How this person writes, when the app has watched long enough to be sure.
        let style = OperatingModel.systemPrompt(from: store.traits())
        // An override replaces the launcher's own instructions rather than being appended to them.
        // The distillation prompt forbids inventing anything and requires a citation on every line;
        // stacking it after "respondes solo con el resultado pedido" leaves two sets of rules and
        // the model picks whichever it likes, which is how uncited lines start appearing.
        // Deliberately not translated. This is addressed to the model, not to the person, and the
        // language of the answer follows the language of what the person selected — not the menu
        // bar. Tying the instruction to the interface language would make an English window answer
        // in English about a Spanish document.
        let system = override ??
                     ("You are a tool inside a launcher. Reply with the requested result only: no "
                      + "greeting, and no explaining what you are about to do."
                      + (style.isEmpty ? "" : "\n\n" + style))

        var lastError: Error?
        for provider in providers {
            do {
                let client = IntelligenceClient()
                let modelProvider = BELLanguageModelProviderFactory.provider(
                    for: provider, client: client)
                let request = BELModelRequest(system: system, prompt: prompt,
                                              sensitivity: sensitivity, maxTokens: 900,
                                              localOnly: router.localOnlyFor.contains(sensitivity)
                                                  || brainContextLevel.requiresLocalExecution,
                                              brainContextLevel: brainContextLevel)
                let response = try await modelProvider.stream(request, model: models[provider.id],
                                                              onFragment: onFragment ?? { _ in })
                await providerHealthCache.record(
                    BELProviderHealth(state: .ready, model: response.model), for: provider.id)
                return response.text
            } catch {
                lastError = error
                await providerHealthCache.record(
                    BELProviderHealth(state: .offline(error.localizedDescription)),
                    for: provider.id
                )
            }
        }
        if let foundation = BELLanguageModelProviderFactory.foundationModelsProvider() {
            do {
                let request = BELModelRequest(system: system, prompt: prompt,
                                              sensitivity: sensitivity, maxTokens: 900,
                                              localOnly: true,
                                              brainContextLevel: brainContextLevel)
                return try await foundation.stream(request, model: nil,
                                                   onFragment: onFragment ?? { _ in }).text
            } catch {
                lastError = error
            }
        }
        throw lastError ?? IntelligenceError.noProviderConfigured
    }

    // MARK: - Welcome

    /// Shown once, and reopenable from the menu bar. Everything the app could do was reachable and
    /// nothing was findable; this is where that gets fixed.
    @objc func openWelcome() {
        guard let store else { return }
        if let window = welcomeWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = settingsModel ?? SettingsModel(
            store: store, appVersion: appVersion,
            updateFeedURL: environment["BELAUNCHER_UPDATE_FEED_URL"] ?? UpdateCheck.defaultFeedURL
        )
        model.calendar = calendar
        model.onRequestNotifications = { [weak self] in
            await self?.requestNotifications() ?? false
        }
        settingsModel = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Bienvenido a BeLauncher"
        window.contentViewController = NSHostingController(rootView: WelcomeView(model: model) {
            [weak self] in
            self?.store?.setSetting("welcomed", true)
            self?.welcomeWindow?.close()
            self?.welcomeWindow = nil
            // The offer for the meaning model waits until the welcome window is out of the way:
            // two windows arriving at once is how people close both without reading either.
            self?.offerBrainSetupIfNeeded()
        })
        window.isReleasedWhenClosed = false
        place(window)
        welcomeWindow = window

        panel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showWelcomeOnFirstRun() {
        guard store?.setting("welcomed", default: false) == false else { return }
        openWelcome()
    }

    // MARK: - The meaning model

    /// Offers to install the embeddings model, once, on a Mac that does not have it.
    ///
    /// The screen existed and nothing opened it: `BrainSetupWindow.present()` was called from
    /// nowhere in the whole source tree, so on a clean Mac the headline feature — search that
    /// understands meaning — was silently missing and the only way to fix it was a trip into
    /// Ajustes, which is exactly the trip the screen exists to avoid.
    ///
    /// Three rules it has to respect. It never blocks the launch: the check asks the local Ollama
    /// server, which on a machine without Ollama means waiting for a connection to be refused, so
    /// it happens after the launcher is already usable. It never fights the welcome window, which
    /// owns the screen on a first run and calls back here when it closes. And it is offered once:
    /// `setupLater` already tells the person where to find it again, and an app that asks every
    /// morning gets its question dismissed unread.
    private func offerBrainSetupIfNeeded() {
        guard let store else { return }
        guard store.setting("brain_setup_offered", default: false) == false else { return }
        guard store.setting("welcomed", default: false) == true else { return }

        Task { @MainActor [weak self] in
            // Long enough for the hot key, the clipboard watcher and the first index pass to be
            // in place. Nothing here is urgent; a window landing on top of what the person is
            // doing two seconds after login is.
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.welcomeWindow == nil else { return }
            guard await BrainSetupWindow.isNeeded() else { return }
            // Written before showing, not after: whichever way the window is dismissed — skipped,
            // closed from the title bar, or the app quit mid-download — it does not come back on
            // its own.
            self.store?.setSetting("brain_setup_offered", true)
            BrainSetupWindow.present(place: { [weak self] window in self?.place(window) })
        }
    }

    /// Asked here rather than in the model so EventKit and UserNotifications stay in the app layer.
    private func requestNotifications() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Returns what went wrong, or nil when the step did what it said.
    ///
    /// It used to return nothing, so a mission marked every step done whether or not it worked —
    /// a receipt that exists to not take the machine's word for it, taking the machine's word for it.
    @discardableResult
    private func perform(_ action: LauncherModel.Action) -> String? {
        switch action {
        case .dismiss:
            aiTask?.cancel()
            panel?.orderOut(nil)

        case .launchApplication(let path):
            note(signature: Autopilot.signature(forApplication: path),
                 label: L("Open %@", (path as NSString).lastPathComponent
                            .replacingOccurrences(of: ".app", with: "")))
            remember(Capture.application(named: (path as NSString).lastPathComponent
                .replacingOccurrences(of: ".app", with: ""), path: path))
            let url = URL(fileURLWithPath: path)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard let error else { return }
                Task { @MainActor in self.report(L("Could not open %@", url.lastPathComponent), error.localizedDescription) }
            }

        case .openURL(let url):
            NSWorkspace.shared.open(url)

        case .openFile(let path):
            remember(Capture.file(at: path))
            store?.observe(OperatingModel.observeFilename((path as NSString).lastPathComponent))
            note(signature: Autopilot.signature(forApplication: path),
                 label: L("Open %@", (path as NSString).lastPathComponent))
            executeStableFileAction(id: "files.open", path: path, confirmed: true)

        case .revealInFinder(let path):
            executeStableFileAction(id: "files.reveal", path: path, confirmed: true)

        case .openWith(let path):
            openWithPicker(path: path)

        case .quickLook(let path):
            // Quick Look through Finder: no extra framework, no extra permission.
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])

        case .moveToTrash(let path):
            let alert = NSAlert()
            alert.messageText = L("Move %@ to the trash?", (path as NSString).lastPathComponent)
            alert.informativeText = L("This cannot be undone.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("Move to the trash"))
            alert.addButton(withTitle: L("Cancel"))
            if alert.runModal() == .alertFirstButtonReturn {
                executeStableFileAction(id: "files.move_to_trash", path: path, confirmed: true)
            }

        case .openSettings:
            openSettings()

        case .assignAlias(let target, let suggestion):
            promptForAlias(target: target, suggestion: suggestion)

        case .runVerb(let id, let text):
            runAIVerb(id: id, text: text)

        case .runMission(let mission):
            runMission(mission)

        case .quitProcess(let pid):
            panel?.orderOut(nil)
            if let failure = SystemUtilities.quit(pid: pid, force: false) {
                report(L("It could not be closed"), failure)
                return failure
            }

        case .forceQuit(let pid):
            panel?.orderOut(nil)
            if let failure = SystemUtilities.quit(pid: pid, force: true) {
                report(L("It could not be forced to quit"), failure)
                return failure
            }

        case .stayAwake(let minutes):
            panel?.orderOut(nil)
            report("Modo despierto", SystemUtilities.stayAwake(minutes: minutes))
            refreshAwakeItem()

        case .writeNote(let text):
            panel?.orderOut(nil)
            switch SystemUtilities.write(note: text, inVaultAt: Vault.defaultRoot()) {
            case .saved(let path):
                store?.observe(OperatingModel.observeWriting(text))
                refreshBrain(force: true)
                report(L("Note saved"), (path as NSString).lastPathComponent)
            case .failed(let why):
                report(L("It could not be saved"), why)
                return why
            }

        case .createSnippet(let text):
            createSnippet(from: text)

        case .openQuickNoteEditor(let initialText):
            openQuickNoteEditor(initialText: initialText)

        case .saveWorkspace(let name):
            panel?.orderOut(nil)
            switch WindowArranger.snapshot(named: name) {
            case .taken(let workspace):
                do {
                    try store?.saveWorkspace(workspace)
                    report(L("Saved “%@”", name),
                           L("%1$@ windows across %2$@ display(s). Type “%3$@” to place them.",
                             String(workspace.placements.count), String(workspace.displays), name))
                } catch {
                    report(L("Open With failed"), error.localizedDescription)
                }
            case .failed(let why):
                report(L("It could not be saved"), why)
                return why
            }

        case .restoreWorkspace(let name):
            panel?.orderOut(nil)
            guard let workspace = store?.workspace(named: name) else {
                report(L("I cannot find it"), L("There is no saved layout by that name."))
                return nil
            }
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            // Said before moving anything, not discovered afterwards.
            if let warning = WorkspaceLayouts.fit(workspace, displays: NSScreen.screens.count,
                                                  runningBundles: running).warning {
                report("Ojo", warning)
            }
            report(L("Placing “%@”", name), WindowArranger.restore(workspace))

        case .cancelAI:
            aiTask?.cancel()
            aiTask = nil

        case .openCanvas(let template, let brief):
            openCanvas(template: template, brief: brief)

        case .runAgent(let id, let argument):
            guard let command = agentRunner?.commands.first(where: { $0.id == id }) else {
                return L("That command is not installed any more.")
            }
            panel?.orderOut(nil)
            agentRunner?.start(command, argument: argument)
            openTray()

        case .missionCancelled:
            break   // the plan was shown and refused: nothing happened, nothing to report

        case .remember(let text, let source):
            rememberIntoVault(text: text, source: source)
            Sounds.play(.proposed)

        case .confirmCommit(let id):
            do {
                let object = try vault?.confirm(commitID: id)
                if let object {
                    rememberMemory(object)
                    refreshBrain(force: true)
                    report(L("Kept in the brain"), object.statement)
                }
            } catch {
                report(L("It could not be confirmed"), "\(error)")
            }

        case .discardCommit(let id):
            try? vault?.discard(commitID: id)

        case .arrangeWindow(let layout):
            // The window belongs to whoever was in front before the launcher appeared. Waiting a
            // beat and asking the system again was the old approach, and it lost the race often
            // enough that arranging windows simply did not work.
            panel?.orderOut(nil)
            let target = appBeforePanel
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if let failure = WindowArranger.arrange(layout, on: target) {
                    self.report(L("The window could not be placed"), failure)
                }
            }

        case .systemCommand(let kind):
            panel?.orderOut(nil)
            if kind.hasPrefix("bel:") {
                let parts = kind.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
                let id = String(parts[0].dropFirst("bel:".count))
                let argument = parts.count == 2 ? String(parts[1]) : ""
                executeStablePublicAction(id: id, argument: argument)
                return nil
            }
            // Not a system action: it opens a window of ours. Handled before the runner rather
            // than inside it, so the runner keeps meaning "things macOS does".
            if kind == SystemCommand.Kind.openBrain.rawValue { openGraph(); return nil }
            let definitionID = BELActionCatalog.all.first {
                BELActionCatalog.systemCommandKind(for: $0.id) == kind
            }?.id
            let definition = definitionID.flatMap(BELActionCatalog.named)
            let command = SystemCommand.all.first { $0.kind.rawValue == kind }
            let confirmed = command?.needsConfirmation != true || {
                let alert = NSAlert()
                alert.messageText = L("%@?", command?.title ?? kind)
                alert.informativeText = L("This cannot be undone.")
                alert.alertStyle = .warning
                alert.addButton(withTitle: L("Continue"))
                alert.addButton(withTitle: L("Cancel"))
                return alert.runModal() == .alertFirstButtonReturn
            }()
            guard confirmed else { return nil }
            // Keep the legacy confirmation UI, then execute through the stable runtime so the
            // adapter, capability gate and receipt are the same path used by newer surfaces.
            if let definition, let handler = BELActionRuntime().handler(for: definition),
               command != nil {
                Task { @MainActor in
                    do {
                        _ = try await BELActionExecutor.execute(definition,
                                                                capabilities: .allGranted,
                                                                confirmed: true, handler: handler)
                    } catch {
                        self.report(L("The command could not be run"), "\(error)")
                    }
                }
                return nil
            }
            let failure = SystemCommandRunner.run(kind) { _ in true }
            if let failure { report(L("The command could not be run"), failure) }
            return failure

        case .runShortcut(let name):
            let alert = NSAlert()
            alert.messageText = L("Run shortcut %@?", name)
            alert.informativeText = L("This shortcut can change settings or control other apps.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("Run"))
            alert.addButton(withTitle: L("Cancel"))
            if alert.runModal() == .alertFirstButtonReturn {
                guard let definition = BELActionCatalog.named("shortcuts.run"),
                      let input = try? JSONEncoder().encode(BELShortcutActionInput(name: name)) else {
                    return L("The shortcut action is unavailable.")
                }
                Task { @MainActor in
                    do {
                        _ = try await BELActionRuntime().execute(definition, input: input,
                                                                 capabilities: .allGranted,
                                                                 confirmed: true)
                    } catch {
                        report(L("The shortcut could not be run"), "\(error)")
                    }
                }
            }

        case .startTimer(let minutes, let label):
            Timers.schedule(minutes: minutes, label: label)

        case .wait:
            break   // only meaningful inside a flow, handled by runFlow

        case .runFlow(let steps):
            runFlow(steps)

        case .copyToClipboard(let text, _):
            clipboard?.ignoreNextChange()
            Sounds.play(.taken)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            if store?.setting("paste_after_copy", default: false) == true {
                // The panel must be gone before the keystroke lands in the previous app.
                panel?.orderOut(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    Permissions.pasteToFrontmostApp()
                }
            }
        }
        return nil
    }

    private func executeStableFileAction(id: String, path: String, confirmed: Bool) {
        guard let definition = BELActionCatalog.named(id),
              let input = try? JSONEncoder().encode(BELPathActionInput(path: path)) else { return }
        Task { @MainActor in
            do {
                _ = try await BELActionRuntime().execute(definition, input: input,
                                                         capabilities: .allGranted,
                                                         confirmed: confirmed)
            } catch BELActionExecutionError.confirmationRequired {
                report(L("Confirmation required"), L("This action cannot be undone."))
            } catch {
                report(L("The file action could not be completed"), "\(error)")
            }
        }
    }

    private func executeStablePublicAction(id: String, argument: String) {
        guard let definition = BELActionCatalog.named(id) else {
            report(L("The action is unavailable"), id)
            return
        }
        let input: Data
        do {
            switch id {
            case "files.extract_pdf_text":
                input = try JSONEncoder().encode(BELPDFActionInput(path: argument))
            case "calendar.upcoming":
                input = try JSONEncoder().encode(BELCalendarActionInput())
            default:
                input = Data()
            }
        } catch {
            report(L("The action could not be prepared"), "\(error)")
            return
        }
        Task { @MainActor in
            do {
                let result = try await BELActionRuntime().execute(definition, input: input,
                                                                  capabilities: .allGranted)
                report(L("Action completed"), result.text)
            } catch {
                report(L("The action could not be completed"), "\(error)")
            }
        }
    }

    /// Walks a planned flow, honouring `.wait` between steps. Sequential on purpose: the whole
    /// point of a flow is that step 3 happens after step 2.
    private func runFlow(_ steps: [LauncherModel.Action]) {
        Task { @MainActor in
            for step in steps {
                if case .wait(let seconds) = step {
                    try? await Task.sleep(for: .seconds(min(seconds, 30)))
                    continue
                }
                // A flow stops at the first step that fails. Carrying on means "silencia,
                // abre Notion, pon un temporizador" ends with a timer running and notifications
                // still on, which is worse than not running at all.
                if perform(step) != nil { break }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    /// Walks an approved mission and writes a receipt of what actually happened. The receipt is
    /// assembled from the steps that ran, never from a model's account of its own work.
    private func runMission(_ mission: Mission,
                            completion: @escaping @Sendable @MainActor (MissionReceipt) -> Void = { _ in }) {
        var executed = mission
        store?.saveActionRun(ActionRunSnapshot(mission: executed))
        commandCoordinator.begin(id: mission.id, label: mission.intent, source: L("Brain"))
        let task = Task { @MainActor in
            do {
                for index in executed.steps.indices {
                    try Task.checkCancellation()
                    let step = executed.steps[index]
                    if let failure = perform(step.action) {
                        executed.steps[index].outcome = .failed
                        executed.steps[index].detail = failure
                        executed.state = .failed
                        executed.failure = failure
                        break
                    }
                    executed.steps[index].outcome = .done
                    store?.saveActionRun(ActionRunSnapshot(mission: executed))
                    try await Task.sleep(for: .milliseconds(150))
                }
                // Do not turn a failed step into a successful mission after the loop breaks. The
                // receipt is the user's trust boundary, so its state must reflect the first real
                // failure rather than the loop's normal completion path.
                if executed.state != .failed {
                    executed.state = .done
                }
            } catch is CancellationError {
                executed.state = .cancelled
                executed.failure = L("Cancelled before all steps finished.")
            }
            executed.finishedAt = .now

            let receipt = MissionReceipt.of(executed, requestedBy: NSFullUserName())
            store?.saveActionRun(ActionRunSnapshot(mission: executed, receipt: receipt.render()))
            lastReceipt = receipt
            persistMissionReceipt(receipt)
            persistMissionOutcome(receipt)
            completion(receipt)
            commandCoordinator.finish(cancelled: executed.state == .cancelled,
                                      failed: executed.state == .failed)
            if !receipt.changed.isEmpty {
                report(L("Mission finished"), receipt.render())
            }
            missionTasks[mission.id] = nil
        }
        missionTasks[mission.id] = task
        commandCoordinator.setCancelAction { [weak self] in
            self?.missionTasks[mission.id]?.cancel()
        }
    }

    /// A receipt is outcome evidence, not transient UI. Keeping it as ordinary Markdown makes it
    /// searchable by the Brain and reviewable in the same Inbox as notes and call evidence.
    private func persistMissionReceipt(_ receipt: MissionReceipt) {
        do {
            let title = L("Mission result: %@", receipt.intent)
            let vault = try Vault(root: Vault.defaultRoot())
            _ = try vault.saveEvidence(title: title, text: receipt.render())
        } catch {
            report(L("Mission result could not be saved"), error.localizedDescription)
        }
    }

    /// Closes the mission as an Outcome Memory as well as a human-readable receipt. The receipt
    /// is evidence of the steps; this object is the durable answer to "what happened?" and keeps
    /// the mission link explicit so the graph can walk back to its action run.
    private func persistMissionOutcome(_ receipt: MissionReceipt) {
        do {
            let vault = try Vault(root: Vault.defaultRoot())
            try vault.save(receipt.outcomeMemory())
            refreshBrain(force: true)
        } catch {
            report(L("Mission outcome could not be saved"), error.localizedDescription)
        }
    }

    private func cancelMission(_ id: String) {
        if commandCoordinator.current?.id == id {
            commandCoordinator.cancel()
        } else {
            missionTasks[id]?.cancel()
        }
    }

    /// Applies a verb and puts the answer in the window. Nothing is copied or pasted behind the
    /// user's back: they see it, then decide.
    private func runAIVerb(id: String, text: String) {
        guard let verb = AIVerb.named(id), let model, let store else { return }

        // A local provider counts as available only when it is actually running. Treating every
        // local provider as present meant picking Ollama with Ollama switched off, then waiting
        // out a 60-second timeout before being told anything.
        model.aiWorking(verb.title)
        aiTask?.cancel()
        aiTask = Task { @MainActor in
            let running = await LocalModels.installed()
            var models: [String: String] = [:]
            for installation in running {
                models[installation.providerID] = store.setting("ai_model_\(installation.providerID)")
                    .flatMap { saved in installation.models.contains(saved) ? saved : nil }
                    ?? installation.models[0]
            }
            let runningIDs = Set(running.map(\.providerID))
            let configured = IntelligenceProvider.all.filter { provider in
                provider.isPrivate
                    ? runningIDs.contains(provider.id)
                    : (Keychain.get(provider.keychainAccount)?.isEmpty == false)
            }
            guard !configured.isEmpty else {
                model.aiFailed(IntelligenceError.noProviderConfigured.description)
                return
            }

            let runner = AIVerbRunner(
                client: IntelligenceClient(),
                router: ModelRouter(preferred: store.setting("ai_provider")),
                providers: configured,
                models: models,
                healthCache: providerHealthCache
            )
            do {
                // Streaming, so the first words land in under a second instead of after the
                // whole answer. Fragments arrive off the main actor; hop back to touch the model.
                let answer = try await runner.run(verb, on: text) { fragment in
                    Task { @MainActor in model.aiStreaming(verb: verb.title, fragment: fragment) }
                }
                model.aiAnswered(verb: verb.title, text: answer)
            } catch let error as IntelligenceError {
                model.aiFailed(error.description)
            } catch {
                model.aiFailed(error.localizedDescription)
            }
        }
    }

    /// Turns a piece of text into a proposed memory. Deliberately a proposal, never a silent
    /// write: the user decides what their brain believes.
    private func rememberIntoVault(text: String, source: String) {
        guard let vault else { return }
        panel?.orderOut(nil)

        let alert = NSAlert()
        alert.messageText = L("Remember this")
        alert.informativeText = L("Write the phrase you will remember it by. It is kept as a proposal until you confirm it.")
        alert.addButton(withTitle: "Proponer")
        alert.addButton(withTitle: L("Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = String(text.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let commit = try vault.propose(
                MemoryObject(level: .extracted, kind: .note, statement: field.stringValue,
                             body: text, source: source, owner: NSFullUserName()),
                reason: L("Captured from BeLauncher")
            )
            report(L("Proposal saved"),
                   commit.conflicts.isEmpty
                     ? L("Look for it and confirm it whenever you want.")
                     : L("Careful: it would clash with %@ memory/memories still standing.", String(commit.conflicts.count)))
        } catch {
            report(L("It could not be saved"), "\(error)")
        }
    }

    /// Asks for the short name and stores it. Kept as a sheet-free alert on purpose: assigning
    /// an alias is a two-second action and should not open a settings window.
    private func promptForAlias(target: String, suggestion: String) {
        panel?.orderOut(nil)
        let alert = NSAlert()
        alert.messageText = L("Alias for %@", (suggestion as NSString).deletingPathExtension)
        alert.informativeText = L("Write the short text you want to find it by. One word, no spaces.")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "nav"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let alias = try store?.setAlias(field.stringValue, target: target)
            if let alias { report("Alias guardado", L("Type “%@” to find it.", alias)) }
        } catch {
            report(L("The alias could not be saved"), "\(error)")
        }
    }

    /// The "Open with…" list macOS itself offers for that file.
    private func openWithPicker(path: String) {
        let url = URL(fileURLWithPath: path)
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        guard !apps.isEmpty else {
            NSWorkspace.shared.open(url)
            return
        }
        let menu = NSMenu(title: L("Open with"))
        for app in apps.prefix(12) {
            let item = NSMenuItem(
                title: FileManager.default.displayName(atPath: app.path),
                action: #selector(openWithChosen(_:)), keyEquivalent: ""
            )
            item.target = self
            item.image = NSWorkspace.shared.icon(forFile: app.path)
            item.image?.size = NSSize(width: 16, height: 16)
            item.representedObject = [url, app]
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func openWithChosen(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [URL], pair.count == 2 else { return }
        NSWorkspace.shared.open([pair[0]], withApplicationAt: pair[1],
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Puts a window where the person is looking: centred, and high rather than dead centre.
    ///
    /// `center()` centres on the *main* screen, which on a Mac with three displays is wherever
    /// macOS decided — usually not the one being used, so windows kept opening off to the side.
    /// The screen under the pointer is the honest answer to "where am I".
    ///
    /// Vertically it sits above the middle. A window centred exactly looks low, because the eye
    /// reads the space under it as heavier; every system dialog on macOS does the same.
    private func place(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        let visible = screen.visibleFrame
        let size = window.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.midY - size.height / 2 + visible.height * 0.10
        // Never push the title bar off the top of the screen on a short display.
        let clamped = min(y, visible.maxY - size.height)
        window.setFrameOrigin(NSPoint(x: x.rounded(), y: clamped.rounded()))
    }

    private func report(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        // .warning paints a yellow triangle on the icon, which makes every message look like
        // something went wrong — including "Guardado en el cerebro". Informational, with the
        // mascot, so the tone matches what is being said.
        alert.alertStyle = .informational
        if let mascot = Mascot.image { alert.icon = mascot }
        alert.runModal()
    }

    private func presentFatal(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "BeLauncher could not open its database"
        alert.informativeText = """
            \(error)

            The file lives at \(Store.defaultPath()). Move it aside and relaunch BeLauncher \
            to start with an empty database.
            """
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.selectFile(Store.defaultPath(), inFileViewerRootedAtPath: "")
        }
        NSApp.terminate(nil)
    }
}

// MARK: - Asking for capture

/// The one screen where the app asks to watch.
///
/// Written as a decision, not as a feature pitch. Somebody deciding whether to let software read
/// their browser history and their conversations needs three things on one screen: exactly what
/// gets read, what never does, and how to stop it afterwards. Splitting those across a marketing
/// panel and a settings tab is how consent becomes a checkbox nobody understood.
///
/// The escape is a real button with a real label, never a greyed-out one and never a close box in
/// the corner. "Ahora no" sits next to "Activar" at the same size on purpose: an offer whose refusal
/// is hard to find is not an offer.
@MainActor
private struct CaptureConsentView: View {

    /// How many apps are already excluded, so the promise is a number rather than an adjective.
    let excluded: Int
    let onDecide: (Bool) -> Void

    private struct Source: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let detail: String
    }

    private var sources: [Source] {
        [
            Source(symbol: "doc.text", title: "Archivos y apps",
                   detail: L("App activity metadata and files opened through BeLauncher. It does not read window or file contents yet.")),
            Source(symbol: "safari", title: L("Browser history"),
                   detail: L("The titles of the pages you read, from Safari and Chrome.")),
            Source(symbol: "bubble.left.and.bubble.right", title: L("Conversations with the AI"),
                   detail: L("What you asked in your own sessions, which are already in your folder.")),
            Source(symbol: "calendar", title: L("Meetings and clipboard"),
                   detail: L("Meeting context after Calendar permission, plus what you copy while capture is enabled.")),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    Divider()
                    list
                    promise
                }
                .padding(26)
            }

            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button(L("Not now")) { onDecide(false) }
                    .keyboardShortcut(.cancelAction)
                Button(L("Turn the memory on")) { onDecide(true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 620, height: 640)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Mascot(height: 96)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Shall it remember what you work on?"))
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.4)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("Without this, BeLauncher only finds what you file by hand. With it, you can ask **how you solved something two months ago** and get an answer."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("WHAT IT WATCHES"))
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)

            ForEach(sources) { source in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: source.symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.title).font(.system(size: 13, weight: .medium))
                        Text(source.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The controls, on the same screen as the question rather than a tab away.
    private var promise: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("AND WHAT IT DOES NOT"))
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)

            guarantee("lock.shield", L("It all stays on this Mac."),
                      L("Nothing goes out to the internet unless you set up a model of your own outside it."))
            guarantee("eye.slash", L("%@ apps are excluded from day one.", String(excluded)),
                      L("Password managers, the keychain and banks. You can add more."))
            guarantee("pause.circle", L("Pause whenever you want."),
                      L("One click stops the capture, and nothing is recorded until you start it again."))
            guarantee("trash", L("And you can make it forget."),
                      L("Delete the last hour, the afternoon or the whole day, and it tells you what goes before it does it."))

            Text(L("You can change any of this in Settings whenever you like."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private func guarantee(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
