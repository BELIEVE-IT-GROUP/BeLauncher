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
    private var hotKey: HotKey?
    private var clipboardHotKey: HotKey?
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
                    events: self.calendar.events
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

        installStatusItem()
        announceUpdateIfAny()
        installKeyMonitor()
        registerHotKey(named: store.setting("hotkey") ?? HotKey.Combo.all[0].label)

        let watcher = ClipboardWatcher(store: store)
        clipboard = watcher
        if store.setting("clipboard_enabled", default: true) { watcher.start() }

        indexApplications()
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

            switch event.keyCode {
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

    private func perform(_ action: LauncherModel.Action) {
        switch action {
        case .dismiss:
            panel?.orderOut(nil)

        case .launchApplication(let path):
            let url = URL(fileURLWithPath: path)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard let error else { return }
                Task { @MainActor in self.report("Could not open \(url.lastPathComponent)", error.localizedDescription) }
            }

        case .openURL(let url):
            NSWorkspace.shared.open(url)

        case .openFile(let path):
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

        case .missionCancelled:
            break   // the plan was shown and refused: nothing happened, nothing to report

        case .remember(let text, let source):
            rememberIntoVault(text: text, source: source)

        case .confirmCommit(let id):
            do {
                let object = try vault?.confirm(commitID: id)
                if let object { report("Guardado en el cerebro", object.statement) }
            } catch {
                report("No se pudo confirmar", "\(error)")
            }

        case .discardCommit(let id):
            try? vault?.discard(commitID: id)

        case .arrangeWindow(let layout):
            // A beat so the previous app is frontmost again before we touch its window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if let failure = WindowArranger.arrange(layout) {
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
                perform(step)
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
                perform(step.action)
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

        let configured = IntelligenceProvider.all.filter { provider in
            provider.isPrivate || (Keychain.get(provider.keychainAccount)?.isEmpty == false)
        }
        guard !configured.isEmpty else {
            model.aiFailed(IntelligenceError.noProviderConfigured.description)
            return
        }

        let runner = AIVerbRunner(
            client: IntelligenceClient(),
            router: ModelRouter(preferred: store.setting("ai_provider")),
            providers: configured
        )
        model.aiWorking(verb.title)
        Task { @MainActor in
            do {
                let answer = try await runner.run(verb, on: text)
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
