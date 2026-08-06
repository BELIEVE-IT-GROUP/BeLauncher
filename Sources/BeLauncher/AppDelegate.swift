import AppKit
import SwiftUI
import BeLauncherCore
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store?
    private var model: LauncherModel?
    private var panel: CommandPanel?
    private var statusItem: NSStatusItem?
    private var updateItem: NSMenuItem?
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
    /// Whoever was in front when the launcher was summoned.
    private var appBeforePanel: NSRunningApplication?
    private var clipboard: ClipboardWatcher?
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?
    private var keyMonitor: Any?
    private var appIndex = AppIndex()
    private var shortcuts: [BeLauncherCore.Shortcut] = []
    private var systemShortcuts: [String] = []
    private var vault: Vault?
    private var lastReceipt: MissionReceipt?
    private let calendar = CalendarAccess()
    private var environment: [String: String] = [:]
    private var activationWindow: NSWindow?
    private var activationModel: ActivationModel?
    private var license: LicenseIdentity?

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
        store.purgeSecrets()
        finishLaunch(store: store)
    }

    private func finishLaunch(store: Store) {
        store.trimClips(
            retentionDays: store.setting("clipboard_retention_days", default: 30),
            maxItems: store.setting("clipboard_max_items", default: 500)
        )

        let model = LauncherModel(
            dataSource: { [weak self] in
                guard let self, let store = self.store else { return SearchInput() }
                return SearchInput(
                    applications: self.appIndex.applications,
                    snippets: store.snippets(),
                    workflows: store.workflows(),
                    clips: store.clips(limit: 300),
                    flows: store.flows(),
                    applicationUses: store.applicationUses(),
                    aliases: store.aliases(),
                    shortcuts: self.shortcuts,
                    systemShortcuts: self.systemShortcuts,
                    memories: self.vault?.current() ?? [],
                    pendingCommits: self.vault?.commits(state: .proposed) ?? [],
                    events: self.calendar.events,
                    packs: store.availablePacks(),
                    workNodes: store.nodes(),
                    workEdges: store.nodes().flatMap { store.edges(from: $0.id) },
                    traits: store.traits()
                )
            },
            fileInfo: { path in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return [] }
                var items: [ResultDetail.Item] = []
                if let size = attributes[.size] as? Int {
                    items.append(.init(label: "Tamaño", value: ByteCountFormatter.string(
                        fromByteCount: Int64(size), countStyle: .file)))
                }
                if let modified = attributes[.modificationDate] as? Date {
                    items.append(.init(label: "Modificado",
                                       value: modified.formatted(date: .abbreviated, time: .shortened)))
                }
                return items
            },
            onLaunch: { [weak self] path in self?.store?.recordLaunch(path: path) },
            onPin: { [weak self] pinned, id in self?.store?.setPinned(pinned, clip: id) },
            onDelete: { [weak self] kind, id in
                guard let store = self?.store else { return }
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
            recordUse: { [weak self] kind, id in self?.store?.recordUse(kind: kind, id: id) },
            perform: { [weak self] action in self?.perform(action) }
        )
        self.model = model

        let panel = CommandPanel(model: model, openSettings: { [weak self] in self?.openSettings() })
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

        installStatusItem()
        announceUpdateIfAny()
        installKeyMonitor()
        registerHotKey(named: store.setting("hotkey") ?? HotKey.Combo.all[0].label)

        let watcher = ClipboardWatcher(store: store)
        clipboard = watcher
        if store.setting("clipboard_enabled", default: true) { watcher.start() }

        indexApplications()
        captureCalendarIntoGraph()
        openWithLaunchQueryIfAny()
        showWelcomeOnFirstRun()
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
        clipboard?.stop()
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
        window.center()
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
        store.purgeSecrets()
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

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = BeLauncherMark.menuBarImage()
            ?? NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "BeLauncher")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let open = NSMenuItem(title: "Abrir BeLauncher", action: #selector(togglePanelFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        // Hidden until there is something to say. An update the person has to go looking for in
        // Settings is not an announcement.
        let update = NSMenuItem(title: "", action: #selector(openSettings), keyEquivalent: "")
        update.target = self
        update.isHidden = true
        menu.addItem(update)
        updateItem = update

        menu.addItem(.separator())
        let guide = NSMenuItem(title: "Guía rápida", action: #selector(openWelcome), keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)
        let settings = NSMenuItem(title: "Ajustes…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let reindex = NSMenuItem(title: "Volver a buscar aplicaciones", action: #selector(rescan), keyEquivalent: "")
        reindex.target = self
        menu.addItem(reindex)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Salir de BeLauncher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
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
            settingsModel?.updateStatus = "Hay una versión nueva: \(release.version)"
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
        screenHotKey = HotKey(combo: .screenAction) { [weak self] in
            self?.readScreenAndOffer()
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
            panel.present()
        }
    }

    @objc private func rescan() { indexApplications() }

    @objc func openSettings() {
        guard let store else { return }
        if let window = settingsWindow {
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
            settingsModel.updateStatus = "Hay una versión nueva: \(pending.version)"
        }
        settingsModel.calendar = calendar
        settingsModel.onRequestNotifications = { [weak self] in self?.requestNotifications() }
        settingsModel.onHotKeyChange = { [weak self] label in self?.registerHotKey(named: label) }
        settingsModel.onClipboardToggle = { [weak self] enabled in
            enabled ? self?.clipboard?.start() : self?.clipboard?.stop()
        }
        self.settingsModel = settingsModel

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Ajustes de BeLauncher"
        window.contentViewController = NSHostingController(rootView: SettingsView(model: settingsModel))
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        panel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
        alert.messageText = "¿Lo convierto en un comando?"
        alert.informativeText = recipe.offer + "\n\nSe guardará como un flujo llamado "
                              + "«\(recipe.suggestedKeyword)», que puedes editar o borrar cuando "
                              + "quieras."
        alert.addButton(withTitle: "Sí, créalo")
        alert.addButton(withTitle: "No, gracias")
        let accepted = alert.runModal() == .alertFirstButtonReturn
        store.markRecipeOffered(recipe.id, accepted: accepted)
        guard accepted else { return }

        let flow = Autopilot.flow(from: recipe)
        do {
            try store.addFlow(keyword: flow.keyword, title: flow.title, steps: flow.steps)
            report("Listo", "Escribe «\(flow.keyword)» para ejecutarlo.")
        } catch {
            report("No se pudo crear el comando", error.localizedDescription)
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
                report("No hay nada que leer",
                       "Selecciona algo, o abre el archivo del que quieres que se ocupe.")
                return
            }
            let subject = ScreenReader.subject(of: context)
            presentOffers(ScreenReader.offers(for: subject), subject: subject, context: context)
        }
    }

    private func presentOffers(_ offers: [ScreenReader.Offer], subject: ScreenReader.Subject,
                               context: ScreenContext) {
        let alert = NSAlert()
        alert.messageText = "\(subject.label), de \(context.origin.label)"
        alert.informativeText = String(context.text.prefix(240))
            + (context.text.count > 240 ? "…" : "")
        for offer in offers { alert.addButton(withTitle: offer.title) }
        alert.addButton(withTitle: "Nada")

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
            rememberIntoVault(text: context.text, source: "Visto en \(context.application)")
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
        window.title = "Misiones"
        window.contentViewController = NSHostingController(rootView: MissionTrayView(runner: runner))
        window.isReleasedWhenClosed = false
        window.center()
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
        window.center()
        canvasWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        _ = store
        model.fillAll()
    }

    /// One question to whichever model is available, used by canvases and agents alike.
    ///
    /// Shared so there is exactly one place that decides which provider answers, which model it
    /// asks for, and what the person's own style adds to the prompt.
    func askModel(_ prompt: String, sensitivity: Sensitivity = .personal,
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
        let provider = try router.provider(for: sensitivity, available: available)

        // How this person writes, when the app has watched long enough to be sure.
        let style = OperatingModel.systemPrompt(from: store.traits())
        let system = "Eres una herramienta dentro de un launcher. Respondes solo con el resultado "
                   + "pedido, sin saludos y sin explicar lo que vas a hacer."
                   + (style.isEmpty ? "" : "\n\n" + style)

        return try await IntelligenceClient().stream(
            IntelligenceRequest(system: system, prompt: prompt, sensitivity: sensitivity,
                                maxTokens: 900),
            using: provider, model: models[provider.id],
            onFragment: onFragment ?? { _ in }
        )
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
        model.onRequestNotifications = { [weak self] in self?.requestNotifications() }
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
        })
        window.isReleasedWhenClosed = false
        window.center()
        welcomeWindow = window

        panel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showWelcomeOnFirstRun() {
        guard store?.setting("welcomed", default: false) == false else { return }
        openWelcome()
    }

    /// Asked here rather than in the model so EventKit and UserNotifications stay in the app layer.
    private func requestNotifications() {
        Task { @MainActor in
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
            settingsModel?.notificationsGranted = granted
        }
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
                 label: "Abrir \((path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""))")
            remember(Capture.application(named: (path as NSString).lastPathComponent
                .replacingOccurrences(of: ".app", with: ""), path: path))
            let url = URL(fileURLWithPath: path)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard let error else { return }
                Task { @MainActor in self.report("Could not open \(url.lastPathComponent)", error.localizedDescription) }
            }

        case .openURL(let url):
            NSWorkspace.shared.open(url)

        case .openFile(let path):
            remember(Capture.file(at: path))
            store?.observe(OperatingModel.observeFilename((path as NSString).lastPathComponent))
            note(signature: Autopilot.signature(forApplication: path),
                 label: "Abrir \((path as NSString).lastPathComponent)")
            NSWorkspace.shared.open(URL(fileURLWithPath: path))

        case .revealInFinder(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])

        case .openWith(let path):
            openWithPicker(path: path)

        case .quickLook(let path):
            // Quick Look through Finder: no extra framework, no extra permission.
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])

        case .moveToTrash(let path):
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            } catch {
                report("No se pudo mover a la papelera", error.localizedDescription)
            }

        case .openSettings:
            openSettings()

        case .assignAlias(let target, let suggestion):
            promptForAlias(target: target, suggestion: suggestion)

        case .runVerb(let id, let text):
            runAIVerb(id: id, text: text)

        case .runMission(let mission):
            runMission(mission)

        case .cancelAI:
            aiTask?.cancel()
            aiTask = nil

        case .openCanvas(let template, let brief):
            openCanvas(template: template, brief: brief)

        case .runAgent(let id, let argument):
            guard let command = agentRunner?.commands.first(where: { $0.id == id }) else {
                return "Ese comando ya no está instalado."
            }
            panel?.orderOut(nil)
            agentRunner?.start(command, argument: argument)
            openTray()

        case .missionCancelled:
            break   // the plan was shown and refused: nothing happened, nothing to report

        case .remember(let text, let source):
            rememberIntoVault(text: text, source: source)

        case .confirmCommit(let id):
            do {
                let object = try vault?.confirm(commitID: id)
                if let object {
                    rememberMemory(object)
                    report("Guardado en el cerebro", object.statement)
                }
            } catch {
                report("No se pudo confirmar", "\(error)")
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
                    self.report("No se pudo colocar la ventana", failure)
                }
            }

        case .systemCommand(let kind):
            panel?.orderOut(nil)
            let failure = SystemCommandRunner.run(kind) { title in
                let alert = NSAlert()
                alert.messageText = "¿\(title)?"
                alert.informativeText = "Esta acción no se puede deshacer."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Continuar")
                alert.addButton(withTitle: "Cancelar")
                return alert.runModal() == .alertFirstButtonReturn
            }
            if let failure { report("No se pudo ejecutar el comando", failure) }
            return failure

        case .runShortcut(let name):
            Shortcuts.run(named: name)

        case .startTimer(let minutes, let label):
            Timers.schedule(minutes: minutes, label: label)

        case .wait:
            break   // only meaningful inside a flow, handled by runFlow

        case .runFlow(let steps):
            runFlow(steps)

        case .copyToClipboard(let text, _):
            clipboard?.ignoreNextChange()
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
    private func runMission(_ mission: Mission) {
        var executed = mission
        Task { @MainActor in
            for index in executed.steps.indices {
                let step = executed.steps[index]
                if let failure = perform(step.action) {
                    executed.steps[index].outcome = .failed
                    executed.steps[index].detail = failure
                    executed.state = .failed
                    executed.failure = failure
                    break
                }
                executed.steps[index].outcome = .done
                try? await Task.sleep(for: .milliseconds(150))
            }
            executed.state = .done
            executed.finishedAt = .now

            let receipt = MissionReceipt.of(executed, requestedBy: NSFullUserName())
            lastReceipt = receipt
            if !receipt.changed.isEmpty {
                report("Misión terminada", receipt.render())
            }
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
                models: models
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
        alert.messageText = "Recordar esto"
        alert.informativeText = "Escribe la frase con la que lo recordarás. "
            + "Se guardará como propuesta hasta que la confirmes."
        alert.addButton(withTitle: "Proponer")
        alert.addButton(withTitle: "Cancelar")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = String(text.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let commit = try vault.propose(
                MemoryObject(level: .extracted, kind: .note, statement: field.stringValue,
                             body: text, source: source, owner: NSFullUserName()),
                reason: "Capturado desde BeLauncher"
            )
            report("Propuesta guardada",
                   commit.conflicts.isEmpty
                     ? "Búscala y confírmala cuando quieras."
                     : "Ojo: chocaría con \(commit.conflicts.count) memoria(s) vigente(s).")
        } catch {
            report("No se pudo guardar", "\(error)")
        }
    }

    /// Asks for the short name and stores it. Kept as a sheet-free alert on purpose: assigning
    /// an alias is a two-second action and should not open a settings window.
    private func promptForAlias(target: String, suggestion: String) {
        panel?.orderOut(nil)
        let alert = NSAlert()
        alert.messageText = "Alias para \((suggestion as NSString).deletingPathExtension)"
        alert.informativeText = "Escribe el texto corto con el que quieres encontrarlo. "
            + "Una sola palabra, sin espacios."
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "nav"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let alias = try store?.setAlias(field.stringValue, target: target)
            if let alias { report("Alias guardado", "Escribe “\(alias)” para encontrarlo.") }
        } catch {
            report("No se pudo guardar el alias", "\(error)")
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
        let menu = NSMenu(title: "Abrir con")
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

    private func report(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
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
