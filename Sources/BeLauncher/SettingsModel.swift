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
    var flows: [Flow] = []
    var shortcutNames: [String] = []
    var secretNames: [String] = []

    var snippetError: String?
    var workflowError: String?
    var flowError: String?
    var secretError: String?
    var launchAtLoginError: String?
    var status: String?
    var updateStatus: String?

    var appVersion: String
    var updateFeedURL: String?

    // MARK: - Intelligence

    /// Which provider answers, and whether its key is actually there. Without this in the UI,
    /// every AI feature in the app is unreachable — the reason this section exists.
    var aiProvider: String {
        didSet { store.setSetting("ai_provider", aiProvider) }
    }
    var confidentialStaysLocal: Bool {
        didSet { store.setSetting("ai_confidential_local", confidentialStaysLocal) }
    }
    var providerKeys: [String: String] = [:]
    var aiStatus: String?

    var configuredProviders: [IntelligenceProvider] {
        IntelligenceProvider.all.filter { provider in
            provider.isPrivate || !(providerKeys[provider.id] ?? "").isEmpty
        }
    }

    func loadProviderKeys() {
        providerKeys = Dictionary(uniqueKeysWithValues: IntelligenceProvider.all.map { provider in
            (provider.id, provider.keychainAccount.isEmpty
                ? "" : (Keychain.get(provider.keychainAccount) ?? ""))
        })
    }

    /// Keys go straight to the Keychain, never to the database and never to an export.
    func saveKey(_ key: String, for provider: IntelligenceProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                Keychain.delete(provider.keychainAccount)
            } else {
                try Keychain.set(trimmed, for: provider.keychainAccount)
            }
            providerKeys[provider.id] = trimmed
            aiStatus = trimmed.isEmpty
                ? "Clave de \(provider.name) borrada."
                : "Clave de \(provider.name) guardada en el Llavero."
        } catch {
            aiStatus = "El Llavero rechazó la clave: \(error)"
        }
    }

    /// Asks the chosen model to say one word. The only way to know a key works is to use it.
    func testIntelligence() {
        let available = configuredProviders
        guard !available.isEmpty else {
            aiStatus = IntelligenceError.noProviderConfigured.description
            return
        }
        aiStatus = "Probando…"
        let router = ModelRouter(
            preferred: aiProvider,
            localOnlyFor: confidentialStaysLocal ? [.confidential] : []
        )
        Task { @MainActor in
            do {
                let provider = try router.provider(for: .personal, available: available)
                let answer = try await IntelligenceClient().answer(
                    IntelligenceRequest(prompt: "Responde solo con la palabra: listo",
                                        sensitivity: .personal, maxTokens: 20),
                    using: provider
                )
                aiStatus = "\(provider.name) responde: \(answer.prefix(40))"
            } catch let error as IntelligenceError {
                aiStatus = error.description
            } catch {
                aiStatus = error.localizedDescription
            }
        }
    }

    // MARK: - Clipboard exclusions

    var excludedApps: [String] = []

    func addExcludedApp(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var apps = store.excludedApps()
        apps.insert(trimmed.lowercased())
        store.setExcludedApps(apps)
        excludedApps = apps.sorted()
    }

    func removeExcludedApp(_ name: String) {
        var apps = store.excludedApps()
        apps.remove(name.lowercased())
        store.setExcludedApps(apps)
        excludedApps = apps.sorted()
    }

    /// Apps that have actually put something on the clipboard, so exclusion is one click and not
    /// a typing exercise.
    var seenApps: [String] {
        Array(Set(store.clips(limit: 300).map(\.sourceApp).filter { !$0.isEmpty })).sorted()
    }

    // MARK: - Aliases

    var aliases: [(alias: String, target: String)] = []

    func removeAlias(_ alias: String) {
        store.removeAlias(alias)
        reload()
    }

    // MARK: - MCP

    var mcpConfig: String {
        """
        {
          "mcpServers": {
            "belauncher": {
              "command": "/Applications/BeLauncher.app/Contents/MacOS/BeLauncher",
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    func copyMCPConfig() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mcpConfig, forType: .string)
        status = "Configuración copiada. Pégala en el archivo de Claude Desktop."
    }
    var license: LicenseIdentity?
    var licenseClient: LicenseClient?
    var licenseStatus: String?
    /// Set when a newer version is available, so the UI can offer a download button.
    var availableUpdate: Release?

    init(store: Store, appVersion: String, updateFeedURL: String?) {
        self.store = store
        self.appVersion = appVersion
        self.updateFeedURL = updateFeedURL
        hotkey = store.setting("hotkey") ?? HotKey.Combo.all[0].label
        clipboardEnabled = store.setting("clipboard_enabled", default: true)
        retentionDays = store.setting("clipboard_retention_days", default: 30)
        maxItems = store.setting("clipboard_max_items", default: 500)
        updateCheckEnabled = store.setting("update_check_enabled", default: false)
        aiProvider = store.setting("ai_provider") ?? "ollama"
        confidentialStaysLocal = store.setting("ai_confidential_local", default: true)
        pasteAfterCopy = store.setting("paste_after_copy", default: false) && Permissions.accessibilityGranted
        launchAtLogin = LaunchAtLogin.isEnabled
        reload()
    }

    func reload() {
        snippets = store.snippets()
        workflows = store.workflows()
        flows = store.flows()
        secretNames = Keychain.names()
        excludedApps = store.excludedApps().sorted()
        aliases = store.aliases().map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
        loadProviderKeys()
        if shortcutNames.isEmpty { shortcutNames = Shortcuts.available() }
    }

    func addFlow(keyword: String, title: String, steps: [FlowStep]) -> Bool {
        do {
            try store.addFlow(keyword: keyword, title: title, steps: steps)
            flowError = nil
            reload()
            return true
        } catch {
            flowError = "\(error)"
            return false
        }
    }

    func updateFlow(_ id: Int64, steps: [FlowStep]) {
        do {
            try store.updateFlowSteps(id: id, steps: steps)
            flowError = nil
            reload()
        } catch {
            flowError = "\(error)"
        }
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

    /// Exports the shared part of the brain, encrypted with a passphrase the team already has.
    /// Believe never sees the key or the contents.
    func exportTeamBundle() {
        guard let vault = try? Vault(root: Vault.defaultRoot()) else { return }
        let shareable = TeamBrain.shareable(vault.objects())
        guard !shareable.isEmpty else {
            status = "No hay memorias marcadas como “shared”. Añade esa etiqueta a las que quieras compartir."
            return
        }
        guard let passphrase = askPassphrase(
            title: "Frase del equipo",
            message: "La misma que use el resto del equipo. No la guardamos ni la vemos: "
                   + "si se pierde, el paquete no se puede abrir."
        ) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = SafeFilename.make("brain-believe", extension: "belaunch")
        panel.message = "Cifrado con la frase del equipo."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let bundle = TeamBrain.Bundle(team: "believe", exportedBy: NSFullUserName(),
                                          objects: shareable, members: [])
            let sealed = try TeamBrain.seal(bundle,
                                            with: TeamBrain.key(fromPassphrase: passphrase,
                                                                team: "believe"))
            try sealed.write(to: url, options: .atomic)
            status = "Exportadas \(shareable.count) memorias cifradas."
        } catch {
            status = "No se pudo exportar: \(error)"
        }
    }

    /// Imports a teammate's bundle. Everything arrives as a proposal, nothing is applied.
    func importTeamBundle() {
        guard let vault = try? Vault(root: Vault.defaultRoot()) else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.message = "Elige el paquete cifrado del equipo."
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }

        guard let passphrase = askPassphrase(
            title: "Frase del equipo",
            message: "La frase con la que se cifró este paquete."
        ) else { return }

        do {
            let bundle = try TeamBrain.open(data,
                                            with: TeamBrain.key(fromPassphrase: passphrase,
                                                                team: "believe"))
            let plan = TeamBrain.plan(bundle, against: vault.objects())
            for object in plan.added {
                _ = try? vault.propose(object, reason: "Del equipo · \(bundle.exportedBy)")
            }
            for conflict in plan.conflicts {
                _ = try? vault.propose(conflict.incoming,
                                       reason: "Del equipo · contradice «\(conflict.existing.statement)»")
            }
            status = "\(plan.added.count + plan.conflicts.count) memorias del equipo esperan tu "
                + "confirmación. Nada se aplicó solo."
        } catch {
            status = "\(error)"
        }
    }

    private func askPassphrase(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Continuar")
        alert.addButton(withTitle: "Cancelar")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else {
            return nil
        }
        return field.stringValue
    }

    /// Alfred keeps its snippets in a known folder, so this needs no file picker.
    func importFromAlfred() {
        let result = Importers.importAlfredSnippets()
        guard !result.snippets.isEmpty || !result.skipped.isEmpty else {
            status = "No encontré snippets de Alfred en este Mac."
            return
        }
        let summary = store.apply(result)
        reload()
        status = "Alfred: \(summary.addedSnippets) snippets importados"
            + (summary.skipped > 0 ? ", \(summary.skipped) omitidos." : ".")
    }

    /// Raycast exports to a JSON file the user picks.
    func importFromRaycast() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Elige el archivo que exportaste desde Raycast."
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }

        let result = Importers.parseRaycastExport(data)
        let summary = store.apply(result)
        reload()
        status = "Raycast: \(summary.addedSnippets) snippets y \(summary.addedWorkflows) enlaces"
            + (summary.skipped > 0 ? ", \(summary.skipped) omitidos." : ".")
    }

    func revealDataFolder() {
        NSWorkspace.shared.selectFile(store.path, inFileViewerRootedAtPath: "")
    }

    /// Installs the update in place. Downloading a DMG and asking the person to drag the app over
    /// the old one is homework, not an update.
    let updater = Updater()

    func installUpdate() {
        guard let release = availableUpdate else { return }
        updater.install(release)
    }

    func checkForUpdates() {
        updateStatus = "Buscando…"
        let feed = updateFeedURL
        let version = appVersion
        Task { @MainActor in
            switch await UpdateCheck.run(feedURL: feed, currentVersion: version) {
            case .notConfigured:
                updateStatus = "No hay feed de actualizaciones configurado."
            case .upToDate:
                updateStatus = "Estás en la última versión (\(version))."
            case .available(let release):
                availableUpdate = release
                updateStatus = "Hay una versión nueva: \(release.version)"
            case .unavailable(let reason):
                updateStatus = "No pudimos consultar las actualizaciones: \(reason)"
            }
            store.setSetting("last_update_check", ISO8601DateFormatter().string(from: .now))
        }
    }

    var maskedKey: String {
        guard let key = license?.key, key.count > 9 else { return "BELN-••••-••••-••••" }
        return "BELN-••••-••••-" + String(key.suffix(4))
    }

    /// Frees this Mac's seat, forgets the license and quits: the next launch asks to activate.
    func deactivateThisMac() {
        guard let license, let client = licenseClient else { return }
        licenseStatus = "Desactivando…"
        Task { @MainActor in
            let ok = await client.deactivate(
                email: license.email, key: license.key, deviceID: license.deviceID
            )
            guard ok else {
                licenseStatus = "No pudimos desactivar ahora. Intenta de nuevo en un momento."
                return
            }
            LicenseVault.clear()
            licenseStatus = "Equipo liberado."
            NSApp.terminate(nil)
        }
    }

    private func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }
}
