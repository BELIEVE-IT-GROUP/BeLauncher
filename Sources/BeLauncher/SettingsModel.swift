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
        graphEnabled = store.setting("graph_enabled", default: false)
        habitsEnabledSetting = store.setting("habits_enabled", default: false)
        learningEnabledSetting = store.setting("learning_enabled", default: false)
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
    /// The house rules that travel with every shared command. Editable as plain text so a team can
    /// say "el tono es directo" without anyone writing code.
    func teamStandards() -> [OutcomePack.Rule] {
        (store.setting("team_standards") ?? "")
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
                return OutcomePack.Rule(name: parts[0], value: parts[1])
            }
    }

    var teamStandardsText: String {
        get { store.setting("team_standards") ?? "" }
        set { store.setSetting("team_standards", newValue) }
    }

    /// Installs the commands from a team bundle, refusing anything whose name is already taken.
    func applyCommands(from bundle: TeamBrain.Bundle) -> String {
        let merge = TeamBrain.planCommands(
            bundle, installedPacks: store.availablePacks(),
            flows: store.flows(), snippets: store.snippets()
        )
        for pack in merge.packs {
            try? store.installPack(pack, source: "equipo: \(bundle.team)")
        }
        for flow in merge.flows {
            try? store.addFlow(keyword: flow.keyword, title: flow.title, steps: flow.steps)
        }
        for snippet in merge.snippets {
            try? store.addSnippet(keyword: snippet.keyword, title: snippet.title,
                                  body: snippet.body)
        }
        if !merge.standards.isEmpty {
            teamStandardsText = merge.standards.map { "\($0.name): \($0.value)" }
                .joined(separator: "\n")
        }
        reloadIntelligenceExtras()

        var parts: [String] = []
        if !merge.packs.isEmpty { parts.append("\(merge.packs.count) comando(s)") }
        if !merge.flows.isEmpty { parts.append("\(merge.flows.count) flujo(s)") }
        if !merge.snippets.isEmpty { parts.append("\(merge.snippets.count) snippet(s)") }
        var text = parts.isEmpty ? "" : "Instalados " + parts.joined(separator: ", ") + ". "
        if !merge.refused.isEmpty {
            text += "Omitidos porque ya tienes uno con ese nombre: "
                  + merge.refused.joined(separator: ", ") + "."
        }
        return text
    }

    func exportTeamBundle() {
        guard let vault = try? Vault(root: Vault.defaultRoot()) else { return }
        let shareable = TeamBrain.shareable(vault.objects())
        // Commands travel too: shared memory alone makes this a company encyclopedia, shared
        // commands make it the company's way of working.
        let sharedPacks = store.installedPacks()
        let sharedFlows = store.flows()
        let sharedSnippets = store.snippets()
        guard !shareable.isEmpty || !sharedPacks.isEmpty || !sharedFlows.isEmpty else {
            status = "No hay nada que compartir todavía: ni memorias marcadas como “shared”, ni "
                   + "comandos, ni flujos propios."
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
            let bundle = TeamBrain.Bundle(
                team: "believe", exportedBy: NSFullUserName(),
                objects: shareable, members: [],
                packs: sharedPacks, flows: sharedFlows, snippets: sharedSnippets,
                standards: teamStandards()
            )
            let sealed = try TeamBrain.seal(bundle,
                                            with: TeamBrain.key(fromPassphrase: passphrase,
                                                                team: "believe"))
            try sealed.write(to: url, options: .atomic)
            status = "Exportadas \(shareable.count) memorias, \(sharedPacks.count) comando(s) y "
                   + "\(sharedFlows.count) flujo(s), todo cifrado."
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
            let commands = applyCommands(from: bundle)
            status = commands + "\(plan.added.count + plan.conflicts.count) memorias del equipo esperan tu "
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

    // MARK: - Permissions, asked from one place

    /// Whether macOS has actually granted these. The onboarding toggles read this, so a switch
    /// never shows "on" for something the system has not agreed to.
    var calendarGranted: Bool { calendar?.isAuthorised ?? false }
    var notificationsGranted = false

    /// Set by the app so Settings can ask for the calendar without owning EventKit.
    var calendar: CalendarAccess?
    var onRequestNotifications: (() -> Void)?

    func requestCalendar() {
        guard let calendar else { return }
        Task { @MainActor in
            await calendar.requestAccessIfNeeded()
            calendar.refresh()
        }
    }

    func requestNotifications() {
        onRequestNotifications?()
    }

    // MARK: - Vault: the promises, made real

    /// Local models actually running, found by asking them. "Si tienes Ollama funciona" put the
    /// checking on the person who came here to not have to check.
    var localInstallations: [LocalModels.Installation] = []
    var localScanned = false

    func scanLocalModels() {
        Task { @MainActor in
            localInstallations = await LocalModels.installed()
            localScanned = true
            // Pick one the person actually has. The app used to ask Ollama for a hardcoded
            // "llama3.2" whether or not it was installed, which is what made translating hang.
            for installation in localInstallations {
                let key = "ai_model_\(installation.providerID)"
                let saved = store.setting(key) ?? ""
                if !installation.models.contains(saved) {
                    store.setSetting(key, installation.models[0])
                }
            }
            selectedLocalModels = Dictionary(uniqueKeysWithValues: localInstallations.map {
                ($0.providerID, store.setting("ai_model_\($0.providerID)") ?? $0.models[0])
            })
        }
    }

    /// Which model each running local runner should be asked for.
    var selectedLocalModels: [String: String] = [:]

    func chooseLocalModel(_ model: String, for providerID: String) {
        store.setSetting("ai_model_\(providerID)", model)
        selectedLocalModels[providerID] = model
    }

    var vaultRoot: String { Vault.defaultRoot() }

    func openInObsidian() {
        guard let url = VaultGuide.obsidianURL(for: vaultRoot) else { return }
        // Obsidian may not be installed; openURL returns false rather than failing loudly.
        if !NSWorkspace.shared.open(url) {
            status = "No encontramos Obsidian. Instálalo y vuelve a intentarlo, o ábrelo tú y elige "
                   + "«Abrir carpeta como almacén» con esta carpeta."
        } else {
            status = "Abriendo tu cerebro en Obsidian."
        }
    }

    func makeVaultGitRepository() {
        switch VaultGuide.makeGitRepository(at: vaultRoot) {
        case .created:
            status = "Listo: tu cerebro es un repositorio git. Añade tu remoto con "
                   + "«git remote add origin …» y haz push cuando quieras."
        case .alreadyGit:
            status = "Ya era un repositorio git."
        case .failed(let reason):
            status = reason
        }
    }

    func rebuildVaultStructure() {
        do {
            let created = try VaultGuide.scaffold(at: vaultRoot)
            status = created.isEmpty
                ? "La estructura ya estaba completa."
                : "Creado: " + created.joined(separator: ", ")
        } catch {
            status = "No se pudo crear la estructura: \(error.localizedDescription)"
        }
    }

    // MARK: - What it watches, and what it learned

    /// Two separate switches on purpose. Someone may want the graph that answers "what was I doing
    /// before the call" without wanting the app to propose new commands, and the reverse.
    var graphEnabled: Bool {
        didSet { store.setSetting("graph_enabled", graphEnabled) }
    }
    var habitsEnabledSetting: Bool {
        didSet { store.setSetting("habits_enabled", habitsEnabledSetting) }
    }
    var learningEnabledSetting: Bool {
        didSet { store.setSetting("learning_enabled", learningEnabledSetting) }
    }

    var recentActions: [LoggedAction] = []
    var learnedTraits: [Trait] = []
    var graphSummary: [(kind: WorkNode.Kind, count: Int)] = []
    var packs: [OutcomePack] = []

    func reloadIntelligenceExtras() {
        recentActions = store.actionLog(limit: 60).reversed()
        learnedTraits = store.traits()
        packs = store.availablePacks()
        let nodes = store.nodes(limit: 2_000)
        graphSummary = WorkNode.Kind.allCases.compactMap { kind in
            let count = nodes.count { $0.kind == kind }
            return count == 0 ? nil : (kind, count)
        }
    }

    func clearHistory() {
        store.clearActionLog()
        store.clearRecipeOffers()
        reloadIntelligenceExtras()
        status = "Historial de acciones borrado."
    }

    func clearGraph() {
        store.clearWorkGraph()
        reloadIntelligenceExtras()
        status = "Memoria de trabajo borrada."
    }

    func forget(_ trait: Trait) {
        store.forgetTrait(trait.name)
        reloadIntelligenceExtras()
    }

    func forgetEverythingLearned() {
        store.forgetAllTraits()
        reloadIntelligenceExtras()
        status = "Olvidado todo lo aprendido sobre cómo trabajas."
    }

    func removePack(_ pack: OutcomePack) {
        store.removePack(id: pack.id)
        reloadIntelligenceExtras()
    }

    /// Exports the installed outcomes so a team can share the same commands.
    func exportPacks() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "comandos-belauncher.json"
        panel.message = "Comparte tus comandos con el equipo."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try OutcomePack.encode(store.installedPacks()).write(to: url)
            status = "Comandos exportados."
        } catch {
            status = "No se pudieron exportar: \(error.localizedDescription)"
        }
    }

    func importPacks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Importar comandos compartidos."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let incoming = try OutcomePack.decode(Data(contentsOf: url))
            let conflicts = OutcomePack.conflicts(incoming, with: store.availablePacks())
            let installable = incoming.filter { pack in
                !conflicts.contains(.verbTaken(pack.verb))
            }
            for pack in installable {
                try store.installPack(pack, source: url.lastPathComponent)
            }
            reloadIntelligenceExtras()
            status = conflicts.isEmpty
                ? "Instalados \(installable.count) comando(s)."
                : "Instalados \(installable.count). Omitidos \(conflicts.count) porque ya tienes "
                  + "un comando con ese nombre."
        } catch {
            status = "\(error)"
        }
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
