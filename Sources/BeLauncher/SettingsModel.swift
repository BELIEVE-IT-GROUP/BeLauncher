import SwiftUI
import AppKit
import BeLauncherCore

@MainActor
@Observable
final class SettingsModel {
    let store: Store
    var onHotKeyChange: (String) -> Void = { _ in }
    var onClipboardToggle: (Bool) -> Void = { _ in } {
        // Whoever sets this is the only thing that can really start or stop the watcher, and it is
        // set after `init`, so the pause read from disk at startup was announced to nobody. Every
        // assignment re-applies it: a pause restored from a previous session is enforced, not just
        // painted.
        didSet {
            captureRunning = nil
            applyCaptureState()
        }
    }

    /// The language the interface is drawn in.
    ///
    /// Stored as an explicit choice rather than following the system, because the two are genuinely
    /// different questions: a Mac set to Spanish belonging to somebody who works in English is not
    /// an edge case, it is most of the market this app is aimed at. Changing it also does not touch
    /// the corpus — the brain stays bilingual whatever this says.
    var language: Language {
        didSet {
            guard language != oldValue else { return }
            store.setSetting("ui_language", language.rawValue)
            Loc.language = language
            onLanguageChange()
        }
    }
    /// Called after the language changes so the app can rebuild what SwiftUI will not: the menu
    /// bar, the panel and anything already on screen were built with the old strings baked in.
    var onLanguageChange: () -> Void = {}

    var hotkey: String { didSet { store.setSetting("hotkey", hotkey); onHotKeyChange(hotkey) } }
    // Goes through `applyCaptureState` rather than the hook directly: turning the clipboard on
    // while capture is paused used to start the watcher anyway.
    var clipboardEnabled: Bool { didSet { store.setSetting("clipboard_enabled", clipboardEnabled); applyCaptureState() } }
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
        language = Language.resolve(stored: store.setting("ui_language"),
                                    systemPreferred: Locale.preferredLanguages)
        hotkey = store.setting("hotkey") ?? HotKey.Combo.all[0].label
        clipboardEnabled = store.setting("clipboard_enabled", default: true)
        retentionDays = store.setting("clipboard_retention_days", default: 30)
        maxItems = store.setting("clipboard_max_items", default: 500)
        updateCheckEnabled = store.setting("update_check_enabled", default: false)
        soundsEnabled = store.setting("sounds_enabled", default: true)
        soundsChrome = store.setting("sounds_chrome", default: false)
        graphEnabled = store.setting("graph_enabled", default: false)
        habitsEnabledSetting = store.setting("habits_enabled", default: false)
        learningEnabledSetting = store.setting("learning_enabled", default: false)
        aiProvider = store.setting("ai_provider") ?? "ollama"
        confidentialStaysLocal = store.setting("ai_confidential_local", default: true)
        pasteAfterCopy = store.setting("paste_after_copy", default: false) && Permissions.accessibilityGranted
        launchAtLogin = LaunchAtLogin.isEnabled
        reload()
        // Reads the stored pause and puts the menu bar item up if there is one. Done here so a
        // pause survives a restart *visibly*: coming back from lunch to an app that is silently
        // still paused is the failure this whole panel is guarding against.
        refreshPrivacy()
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

    // MARK: - Privacidad: parar, no mirar, olvidar

    /// Which panel Ajustes should land on. Set from outside the window — today by the menu bar
    /// item that appears while capture is paused, which has to be able to take somebody straight
    /// to the control that undoes it rather than to whatever tab was open last.
    var requestedSection: String?

    var privacy = Privacy.State()
    var excludedForCapture: [String] = []
    var excludedCaptureDomains: [String] = []
    /// Said out loud when the stored list cannot express what the person just asked for.
    var exclusionNote: String?

    func refreshPrivacy() {
        privacy = store.privacyState
        excludedForCapture = store.excludedFromCapture().sorted()
        excludedCaptureDomains = store.excludedDomains().sorted()
        // Every refresh, not only the ones that changed something: this is what takes the menu bar
        // item down by itself, and turns capture back on, when a timed pause runs out.
        applyCaptureState()
        PauseIndicator.shared.show(privacy, model: self)
    }

    /// Last value handed to the clipboard hook, so a refresh every twenty seconds does not restart
    /// the watcher every twenty seconds.
    private var captureRunning: Bool?

    /// Stops the capture that exists today instead of only writing down that it should stop.
    ///
    /// Nothing else in the app reads `privacyState` yet: the wave two sources are still being
    /// written, and the only live capture is the clipboard watcher. A pause that records "en
    /// pausa" and keeps recording is precisely the failure this panel exists to prevent, so it is
    /// switched off through the same hook the clipboard toggle uses. When the other sources land
    /// they should read `store.privacyState` themselves and this can go.
    private func applyCaptureState() {
        let shouldRun = privacy.isCapturing() && clipboardEnabled
        guard captureRunning != shouldRun else { return }
        captureRunning = shouldRun
        onClipboardToggle(shouldRun)
    }

    func pause(_ choice: PrivacyCopy.PauseChoice) {
        store.pauseCapture(choice.reason, until: choice.until())
        refreshPrivacy()
    }

    func resumeCapture() {
        store.pauseCapture(.notPaused)
        refreshPrivacy()
    }

    /// Writes the *effective* list back, not the stored one.
    ///
    /// `excludedFromCapture()` falls back to the factory list while the stored set is empty, so
    /// saving only the newly typed name would silently drop the password managers the moment
    /// somebody excluded their first app. Reading the effective set and adding to it keeps the
    /// list on screen equal to the list that is enforced.
    func addExcludedFromCapture(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, PrivacyCopy.problem(withApp: trimmed) == nil else { return }
        var apps = store.excludedFromCapture()
        apps.insert(trimmed)
        store.setExcludedApps(apps)
        exclusionNote = nil
        refreshPrivacy()
        excludedApps = store.excludedApps().sorted()
    }

    func removeExcludedFromCapture(_ name: String) {
        var apps = store.excludedFromCapture()
        apps.remove(name.lowercased())
        // An empty stored list reads as "never configured", which brings the factory ones back on
        // the next read. Rather than let the row reappear with no explanation, it is said.
        if apps.isEmpty {
            exclusionNote = "Era la última de la lista, así que vuelven las de fábrica. Para no "
                          + "excluir ninguna app, deja solo una que no uses."
        } else {
            exclusionNote = nil
        }
        store.setExcludedApps(apps)
        refreshPrivacy()
        excludedApps = store.excludedApps().sorted()
    }

    func addExcludedDomain(_ input: String) {
        guard let domain = PrivacyCopy.normalisedDomain(input) else { return }
        var domains = store.excludedDomains()
        domains.insert(domain)
        store.setExcludedDomains(domains)
        exclusionNote = nil
        refreshPrivacy()
    }

    func removeExcludedDomain(_ domain: String) {
        var domains = store.excludedDomains()
        domains.remove(domain)
        store.setExcludedDomains(domains)
        refreshPrivacy()
    }

    // MARK: - Olvidar, que no tiene vuelta

    enum ForgetState: Equatable {
        case idle
        case counting
        case ready(Privacy.Forgetting)
        case failed(String)
    }

    var forgetChoice: PrivacyCopy.ForgetChoice = .lastHour {
        // Changing the period invalidates the count on screen. Leaving a stale number next to a
        // delete button is how somebody agrees to erase three things and erases nine hundred.
        didSet { if forgetChoice != oldValue { cancelForgetPreview() } }
    }
    var forgetFrom = Date.now.addingTimeInterval(-3600)
    var forgetTo = Date.now
    var forgetState: ForgetState = .idle
    var forgetResult: String?

    private var forgetPeriod: Privacy.Period? {
        forgetChoice == .range
            ? Privacy.Period(from: forgetFrom, to: forgetTo)
            : forgetChoice.period()
    }

    func cancelForgetPreview() {
        forgetState = .idle
        forgetResult = nil
    }

    /// Counts first, always. Nothing here deletes: this is the number the confirmation quotes.
    func countWhatWouldBeForgotten() {
        guard let period = forgetPeriod else { return }
        forgetState = .counting
        forgetResult = nil
        Task { @MainActor in
            let counted = self.store.whatWouldBeForgotten(period)
            self.forgetState = .ready(counted)
        }
    }

    /// The second gate: a modal whose default key is Cancelar, and a destructive button that names
    /// the number. Both Return and Escape leave everything where it is.
    func confirmAndForget() {
        guard case .ready(let counted) = forgetState, let period = forgetPeriod else { return }
        let confirmation = PrivacyCopy.confirmation(period: forgetChoice.label,
                                                    forgetting: counted)
        guard confirmation.canProceed else { return }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        // Cancel is added first so it is the one Return presses. The order matters more than it
        // looks: the default button of a critical alert is the one a person hits without reading.
        alert.addButton(withTitle: confirmation.cancelTitle)
        let destructive = alert.addButton(withTitle: confirmation.confirmTitle)
        destructive.hasDestructiveAction = true
        // No key equivalent on the destructive button, so no keystroke can reach it.
        destructive.keyEquivalent = ""
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        let removed = store.forget(period)
        // Counted again afterwards rather than trusting the return value: `forget` swallows SQLite
        // errors, so the only way to know the rows are gone is to look for them.
        let left = store.whatWouldBeForgotten(period)
        forgetState = .idle
        forgetResult = left.isEmpty
            ? PrivacyCopy.forgotten(removed, period: forgetChoice.label)
            : PrivacyCopy.forgetFailed(left: left.total)
        refreshBrainState()
        reloadIntelligenceExtras()
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
        refreshMCPConnections()
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

    // MARK: - Connecting the assistant you already use

    var mcpConnections: [String: Bool] = [:]

    func refreshMCPConnections() {
        mcpConnections = Dictionary(uniqueKeysWithValues: MCPClient.all.map { client in
            let data = FileManager.default.contents(atPath: client.absoluteConfigPath())
            return (client.id, MCPSetup.isConnected(data, client: client))
        })
    }

    /// The path an assistant should launch. Inside the app bundle, so an update moves with it.
    var mcpExecutablePath: String {
        Bundle.main.executablePath ?? "/Applications/BeLauncher.app/Contents/MacOS/BeLauncher"
    }

    /// The last thing that happened in the MCP section, shown inside that section.
    ///
    /// It used to be written to `status`, which is painted under "Llevártelo a otro sitio" — the
    /// Obsidian and git block, several sections above. So pressing "Conectar" changed a line of
    /// text nowhere near the button, and the section that had just been used said nothing at all.
    var mcpStatus: String?

    func connect(_ client: MCPClient) {
        let path = client.absoluteConfigPath()
        let existing = FileManager.default.contents(atPath: path)
        do {
            let merged = try MCPSetup.merge(into: existing, client: client,
                                            executablePath: mcpExecutablePath)
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try merged.data.write(to: URL(fileURLWithPath: path), options: .atomic)
            refreshMCPConnections()
            // Says what happened — a file was written — and sends the person to the probe. The
            // old wording claimed "X ya puede consultar tu cerebro", which is the unverified
            // claim this whole panel exists to replace.
            mcpStatus = merged.wasAlready
                ? BrainSetupCopy.connectAlreadyThere(client: client.name)
                : BrainSetupCopy.connectWrote(client: client.name)
        } catch let error as MCPSetupError {
            mcpStatus = error.description
        } catch {
            mcpStatus = MCPSetupError.notWritable(client.name).description
        }
        // Writing the file proves intent, not connection. The old panel stopped here and turned
        // the dot green; the report from the last probe is now stale for *this* client, so its
        // verdict goes back to "sin comprobar". The other clients were not touched and keep
        // theirs — wiping every report left the panel with no verdict at all right after using it.
        mcpReports.removeAll { $0.clientName == client.name }
    }

    /// What the last real probe found, one report per client. Empty means nobody has checked,
    /// which the UI shows as its own state instead of assuming the good one.
    var mcpReports: [MCPHealth.Report] = []
    var mcpChecking = false

    func report(for client: MCPClient) -> MCPHealth.Report? {
        mcpReports.first { $0.clientName == client.name }
    }

    /// Launches BeLauncher the way an assistant would and asks it a question whose answer is
    /// planted beforehand. Takes seconds, so it is never done on opening Ajustes: an automatic
    /// check that spawns a subprocess every time someone looks at a settings tab is a check
    /// people learn to resent.
    func runMCPDiagnosis() {
        guard !mcpChecking else { return }
        mcpChecking = true
        let path = mcpExecutablePath
        Task { @MainActor in
            let reports = await MCPProbe.diagnose(executablePath: path)
            self.mcpReports = reports
            self.refreshMCPConnections()
            self.mcpChecking = false
        }
    }

    // MARK: - What the brain actually holds

    /// Set by the app delegate when it has one, so Ajustes reports on the same brain the launcher
    /// searches. Left nil in contexts that never built one, where reading the store directly is
    /// still correct — the index lives in the database, not in this object.
    var brain: BrainSearch?

    var brainReadout: BrainSetupCopy.IndexReadout?
    var brainRebuilding = false
    var brainStatus: String?
    /// Set when the numbers could not be read at all. Distinct from "there is nothing indexed":
    /// one of them is an empty brain and the other is a broken panel, and showing zeros for the
    /// second is how somebody concludes their notes disappeared.
    var brainError: String?
    var brainCards: [PrivacyCopy.Brain.Card] = []
    var brainIsLocal = true

    private func brainForReading() -> BrainSearch {
        if let brain { return brain }
        let made = BrainSearch(store: store)
        brain = made
        return made
    }

    func refreshBrainState() {
        brainError = nil
        brainReadout = nil
        Task { @MainActor in
            let brain = self.brainForReading()
            // Only when nobody detected one yet: re-detecting on every visit would shell out to
            // Ollama for an answer the launcher already has.
            if brain.engine == nil { await brain.detectEngine() }
            let progress = brain.progress()
            self.brainIsLocal = brain.engine?.isLocal ?? true
            self.brainReadout = BrainSetupCopy.readout(
                passages: progress.passages, vectorised: progress.vectorised,
                engine: brain.engine?.model, isLocal: brain.engine?.isLocal ?? false
            )
            self.brainCards = self.countWhatItKnows(passages: progress.passages,
                                                    vectorised: progress.vectorised)
        }
    }

    /// The two counts the index does not keep: how many stretches of work it can tell apart, and
    /// how many names it recognises.
    ///
    /// Both are derived here with the same pure code the rest of the app uses rather than with a
    /// second rule invented for a settings panel. A number on this screen that is computed
    /// differently from the number the launcher answers with is a number that will disagree with
    /// it one day, and the disagreement is what destroys the trust this panel exists to build.
    private func countWhatItKnows(passages: Int,
                                  vectorised: Int) -> [PrivacyCopy.Brain.Card] {
        let nodes = store.nodes(limit: 2_000)
        let clips = store.clips(limit: 1_000)

        var signals = nodes.compactMap { node -> Episode.Signal? in
            let kind: Episode.Signal.Kind?
            switch node.kind {
            case .file: kind = .file
            case .meeting: kind = .meeting
            case .conversation: kind = .conversation
            case .application: kind = .application
            default: kind = nil
            }
            guard let kind else { return nil }
            return Episode.Signal(at: node.lastSeen, kind: kind, subject: node.id, title: node.name)
        }
        signals += clips.map {
            Episode.Signal(at: $0.createdAt, kind: .clip, subject: "clip:\($0.id)",
                           title: String($0.text.prefix(60)))
        }

        let entities = nodes.count { $0.kind == .person || $0.kind == .company
                                     || $0.kind == .project }
        return PrivacyCopy.Brain.cards(
            passages: passages, vectorised: vectorised,
            episodes: EpisodeBuilder.episodes(from: signals).count,
            entities: entities, clips: clips.count
        )
    }

    /// Throws the index away and builds it again from the vault, the work graph and the
    /// clipboard. Nothing here touches a note: the passages are derived, so the worst outcome of
    /// pressing this is time.
    func rebuildIndex() {
        guard !brainRebuilding else { return }
        brainRebuilding = true
        brainStatus = BrainSetupCopy.rebuildRunning
        Task { @MainActor in
            defer { self.brainRebuilding = false }
            let brain = self.brainForReading()
            if brain.engine == nil { await brain.detectEngine() }

            self.store.clearSemanticIndex()
            let vault = try? Vault(root: Vault.defaultRoot())
            brain.index(memories: vault?.objects() ?? [],
                        nodes: self.store.nodes(limit: 2_000),
                        clips: self.store.clips(limit: 500))
            self.refreshBrainState()

            guard brain.engine != nil else {
                self.brainStatus = "Índice rehecho. Sin modelo, se busca por palabras exactas."
                return
            }
            // One batch at a time rather than `embedEverything`, so the counter climbs while it
            // runs. A number that only appears at the end is a spinner with extra steps.
            do {
                while try await brain.embedPending() > 0 {
                    self.refreshBrainState()
                }
                let progress = brain.progress()
                self.brainStatus = BrainSetupCopy.rebuildFinished(
                    passages: progress.passages, vectorised: progress.vectorised)
            } catch {
                self.brainStatus = "El modelo dejó de responder a mitad. Lo indexado se queda "
                    + "guardado: vuelve a pulsar y sigue desde donde iba."
            }
            self.refreshBrainState()
        }
    }

    // MARK: - Sonido

    var soundsEnabled: Bool {
        didSet {
            store.setSetting("sounds_enabled", soundsEnabled)
            Sounds.enabled = soundsEnabled
        }
    }
    var soundsChrome: Bool {
        didSet {
            store.setSetting("sounds_chrome", soundsChrome)
            Sounds.chromeEnabled = soundsChrome
        }
    }

    /// Lets someone hear a cue before deciding whether they want it fifty times a day.
    func preview(_ cue: Sound.Cue) { Sounds.preview(cue) }

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
