import AppKit
import SwiftUI
import BeaconCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store?
    private var model: LauncherModel?
    private var panel: CommandPanel?
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var clipboard: ClipboardWatcher?
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?
    private var keyMonitor: Any?
    private var appIndex = AppIndex()
    private var environment: [String: String] = [:]

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
        store.seedIfEmpty()
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
                    clips: store.clips(limit: 300)
                )
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
        installKeyMonitor()
        registerHotKey(named: store.setting("hotkey") ?? HotKey.Combo.all[0].label)

        let watcher = ClipboardWatcher(store: store)
        clipboard = watcher
        if store.setting("clipboard_enabled", default: true) { watcher.start() }

        indexApplications()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.invalidate()
        clipboard?.stop()
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: - Wiring

    private func indexApplications() {
        model?.isIndexing = true
        Task { @MainActor in
            let index = await Task.detached(priority: .userInitiated) { AppIndex.scan() }.value
            appIndex = index
            model?.isIndexing = false
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Beacon")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Beacon", action: #selector(togglePanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let reindex = NSMenuItem(title: "Rescan Applications", action: #selector(rescan), keyEquivalent: "")
        reindex.target = self
        menu.addItem(reindex)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Beacon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow, let model = self.model else { return event }

            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
                self.openSettings()
                return nil
            }
            switch event.keyCode {
            case 125: model.handle(.down); return nil     // arrow down
            case 126: model.handle(.up); return nil       // arrow up
            case 36, 76: model.handle(.enter); return nil // return / enter
            case 53: model.handle(.escape); return nil    // escape
            case 48: return model.handle(.tab) ? nil : event
            default: return event
            }
        }
    }

    private func registerHotKey(named label: String) {
        hotKey?.invalidate()
        hotKey = HotKey(combo: .named(label)) { [weak self] in self?.togglePanel() }
        if hotKey == nil {
            // Another app already owns this shortcut — say so instead of failing silently.
            let alert = NSAlert()
            alert.messageText = "Beacon could not register \(label)"
            alert.informativeText = "Another app is already using that shortcut. Pick a different one in Settings."
            alert.runModal()
        }
    }

    // MARK: - Actions

    @objc func togglePanel() {
        guard let panel, let model else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            model.activate()
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
            updateFeedURL: environment["BEACON_UPDATE_FEED_URL"]
        )
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
        window.title = "Beacon Settings"
        window.contentViewController = NSHostingController(rootView: SettingsView(model: settingsModel))
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        panel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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

    private func report(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func presentFatal(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Beacon could not open its database"
        alert.informativeText = """
            \(error)

            The file lives at \(Store.defaultPath()). Move it aside and relaunch Beacon \
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
