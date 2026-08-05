import SwiftUI
import AppKit
import BeLauncherCore

@MainActor
@Observable
final class SettingsModel {
    let store: Store
    var onHotKeyChange: (String) -> Void = { _ in }
    var onClipboardToggle: (Bool) -> Void = { _ in }

    var hotkey: String { didSet { store.setSetting("hotkey", hotkey); onHotKeyChange(hotkey) } }
    var clipboardEnabled: Bool { didSet { store.setSetting("clipboard_enabled", clipboardEnabled); onClipboardToggle(clipboardEnabled) } }
    var retentionDays: Int { didSet { store.setSetting("clipboard_retention_days", retentionDays) } }
    var maxItems: Int { didSet { store.setSetting("clipboard_max_items", maxItems) } }
    var updateCheckEnabled: Bool { didSet { store.setSetting("update_check_enabled", updateCheckEnabled) } }
    var pasteAfterCopy: Bool {
        didSet {
            guard pasteAfterCopy != oldValue else { return }
            // Just-in-time: the permission is only requested when the user turns this on.
            if pasteAfterCopy, !Permissions.requestAccessibility(
                reason: "You asked BeLauncher to paste straight into the app you were using."
            ) {
                pasteAfterCopy = false   // don't pretend the feature is on
                return
            }
            store.setSetting("paste_after_copy", pasteAfterCopy)
        }
    }
    var launchAtLogin: Bool {
        didSet {
            do {
                try LaunchAtLogin.set(launchAtLogin)
                store.setSetting("launch_at_login", launchAtLogin)
            } catch {
                launchAtLoginError = "Could not change this setting: \(error.localizedDescription). " +
                    "Launch at login only works when BeLauncher runs from a real .app bundle."
                launchAtLogin = LaunchAtLogin.isEnabled
            }
        }
    }

    var snippets: [Snippet] = []
    var workflows: [Workflow] = []
    var secretNames: [String] = []

    var snippetError: String?
    var workflowError: String?
    var secretError: String?
    var launchAtLoginError: String?
    var status: String?
    var updateStatus: String?

    var appVersion: String
    var updateFeedURL: String?

    init(store: Store, appVersion: String, updateFeedURL: String?) {
        self.store = store
        self.appVersion = appVersion
        self.updateFeedURL = updateFeedURL
        hotkey = store.setting("hotkey") ?? HotKey.Combo.all[0].label
        clipboardEnabled = store.setting("clipboard_enabled", default: true)
        retentionDays = store.setting("clipboard_retention_days", default: 30)
        maxItems = store.setting("clipboard_max_items", default: 500)
        updateCheckEnabled = store.setting("update_check_enabled", default: false)
        pasteAfterCopy = store.setting("paste_after_copy", default: false) && Permissions.accessibilityGranted
        launchAtLogin = LaunchAtLogin.isEnabled
        reload()
    }

    func reload() {
        snippets = store.snippets()
        workflows = store.workflows()
        secretNames = Keychain.names()
    }

    // MARK: - Editing

    func addSnippet(keyword: String, title: String, body: String) -> Bool {
        do {
            try store.addSnippet(keyword: keyword, title: title, body: body)
            snippetError = nil
            reload()
            return true
        } catch {
            snippetError = "\(error)"
            return false
        }
    }

    func addWorkflow(keyword: String, title: String, template: String) -> Bool {
        do {
            try store.addWorkflow(keyword: keyword, title: title, urlTemplate: template)
            workflowError = nil
            reload()
            return true
        } catch {
            workflowError = "\(error)"
            return false
        }
    }

    func addSecret(name: String, value: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else {
            secretError = "Secret names cannot be empty or contain spaces."
            return false
        }
        guard !value.isEmpty else {
            secretError = "The secret value cannot be empty."
            return false
        }
        do {
            try Keychain.set(value, for: trimmed)
            secretError = nil
            reload()
            return true
        } catch {
            secretError = "The Keychain refused to store this secret (\(error))."
            return false
        }
    }

    // MARK: - Data

    func export(includeClipboard: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SafeFilename.make(
            "belauncher-backup-\(dateStamp())", extension: "json"
        )
        panel.allowedContentTypes = [.json]
        panel.message = "Everything except your secrets is written in plain, readable JSON."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Archive.encode(store.exportArchive(includeClipboard: includeClipboard))
            try data.write(to: url, options: .atomic)
            status = "Exported to \(url.path)"
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }

    func importArchive() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Existing keywords are kept; matching entries in the file are skipped."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let archive = try Archive.decode(try Data(contentsOf: url))
            let summary = store.importArchive(archive)
            reload()
            status = "Imported \(summary.addedSnippets) snippets and \(summary.addedWorkflows) workflows" +
                (summary.skipped > 0 ? ", skipped \(summary.skipped) duplicates." : ".")
        } catch {
            status = "Import failed: \(error)"
        }
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SafeFilename.make("belauncher-diagnostics-\(dateStamp())", extension: "txt")
        panel.message = "A plain-text summary. Read it before you share it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let report = store.diagnostics(
            appVersion: appVersion,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            accessibilityGranted: Permissions.accessibilityGranted
        )
        do {
            try report.render().write(to: url, atomically: true, encoding: .utf8)
            status = "Diagnostics written to \(url.path)"
        } catch {
            status = "Could not write diagnostics: \(error.localizedDescription)"
        }
    }

    func revealDataFolder() {
        NSWorkspace.shared.selectFile(store.path, inFileViewerRootedAtPath: "")
    }

    func checkForUpdates() {
        updateStatus = "Checking…"
        let feed = updateFeedURL
        let version = appVersion
        Task { @MainActor in
            switch await UpdateCheck.run(feedURL: feed, currentVersion: version) {
            case .notConfigured:
                updateStatus = "No update feed is configured. Set BELAUNCHER_UPDATE_FEED_URL in your .env file."
            case .upToDate:
                updateStatus = "BeLauncher \(version) is up to date."
            case .available(let release):
                updateStatus = "Version \(release.version) is available: \(release.url)"
            case .unavailable(let reason):
                updateStatus = "Could not reach the update feed: \(reason)"
            }
            store.setSetting("last_update_check", ISO8601DateFormatter().string(from: .now))
        }
    }

    private func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }
}

@MainActor
struct SettingsView: View {
    @Bindable var model: SettingsModel

    @State private var snippetKeyword = ""
    @State private var snippetTitle = ""
    @State private var snippetBody = ""
    @State private var workflowKeyword = ""
    @State private var workflowTitle = ""
    @State private var workflowTemplate = ""
    @State private var secretName = ""
    @State private var secretValue = ""

    var body: some View {
        Form {
            Section("General") {
                Picker("Global hotkey", selection: $model.hotkey) {
                    ForEach(HotKey.Combo.all, id: \.label) { Text($0.label).tag($0.label) }
                }
                Toggle("Launch BeLauncher at login", isOn: $model.launchAtLogin)
                if let error = model.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Check for updates (opt-in)", isOn: $model.updateCheckEnabled)
                HStack {
                    Button("Check now") { model.checkForUpdates() }
                        .disabled(!model.updateCheckEnabled)
                    if let status = model.updateStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Text("BeLauncher has no account, no analytics and no server. Updates are only checked when you ask.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Clipboard history") {
                Toggle("Keep a history of copied text", isOn: $model.clipboardEnabled)
                Stepper("Delete entries after \(model.retentionDays) days", value: $model.retentionDays, in: 1...365)
                Stepper("Keep at most \(model.maxItems) entries", value: $model.maxItems, in: 20...5000, step: 20)
                Toggle("Paste into the frontmost app after choosing an item", isOn: $model.pasteAfterCopy)
                Text("Password-manager copies, transient and non-text items are never recorded.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear clipboard history") {
                    model.store.clearClips()
                    model.status = "Clipboard history cleared."
                }
            }

            Section("Snippets") {
                if model.snippets.isEmpty {
                    Text("No snippets yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.snippets) { snippet in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(snippet.title)
                            Text("\(snippet.keyword) · \(snippet.body.prefix(48))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button {
                            model.store.deleteSnippet(id: snippet.id)
                            model.reload()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Divider()
                TextField("Keyword", text: $snippetKeyword)
                TextField("Title", text: $snippetTitle)
                TextField("Text", text: $snippetBody, axis: .vertical).lineLimit(2...5)
                if let error = model.snippetError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text("Tokens: {clipboard} {date} {date:EEEE} {time} {uuid} {cursor} {secret:NAME}")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add snippet") {
                        if model.addSnippet(keyword: snippetKeyword, title: snippetTitle, body: snippetBody) {
                            snippetKeyword = ""; snippetTitle = ""; snippetBody = ""
                        }
                    }
                }
            }

            Section("Workflows") {
                if model.workflows.isEmpty {
                    Text("No workflows yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.workflows) { workflow in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(workflow.title)
                            Text("\(workflow.keyword) · \(workflow.urlTemplate)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button {
                            model.store.deleteWorkflow(id: workflow.id)
                            model.reload()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Divider()
                TextField("Keyword", text: $workflowKeyword)
                TextField("Title", text: $workflowTitle)
                TextField("URL template", text: $workflowTemplate, prompt: Text("https://example.com/search?q={query}"))
                if let error = model.workflowError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text("Workflows only open http, https and mailto URLs. BeLauncher never runs scripts.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add workflow") {
                        if model.addWorkflow(keyword: workflowKeyword, title: workflowTitle, template: workflowTemplate) {
                            workflowKeyword = ""; workflowTitle = ""; workflowTemplate = ""
                        }
                    }
                }
            }

            Section("Secrets (macOS Keychain)") {
                ForEach(model.secretNames, id: \.self) { name in
                    HStack {
                        Label(name, systemImage: "key.fill")
                        Spacer()
                        Button {
                            Keychain.delete(name)
                            model.reload()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Name", text: $secretName)
                    SecureField("Value", text: $secretValue)
                    Button("Store") {
                        if model.addSecret(name: secretName, value: secretValue) {
                            secretName = ""; secretValue = ""
                        }
                    }
                }
                if let error = model.secretError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Text("Values live in the Keychain, never in the database and never in an export. " +
                     "Use them in snippets or workflow URLs as {secret:NAME}.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Your data") {
                LabeledContent("Database") {
                    Text(model.store.path).font(.caption).textSelection(.enabled).lineLimit(2)
                }
                HStack {
                    Button("Export…") { model.export(includeClipboard: false) }
                    Button("Export with clipboard history…") { model.export(includeClipboard: true) }
                    Button("Import…") { model.importArchive() }
                }
                HStack {
                    Button("Export diagnostics…") { model.exportDiagnostics() }
                    Button("Reveal in Finder") { model.revealDataFolder() }
                }
                if let status = model.status {
                    Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("""
                     To uninstall: quit BeLauncher, turn off “Launch at login”, delete BeLauncher.app, then \
                     delete ~/Library/Application Support/BeLauncher. Secrets are removed from Keychain \
                     Access under “com.believe.belauncher.secrets”. Nothing else is written anywhere.
                     """)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Version", value: model.appVersion)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 700)
    }
}
