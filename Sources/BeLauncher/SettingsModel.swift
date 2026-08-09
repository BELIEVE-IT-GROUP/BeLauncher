import SwiftUI
import AppKit
import UserNotifications
import BeLauncherCore

@MainActor
@Observable
final class SettingsModel {
    let store: Store
    private let loadsSecureState: Bool
    var onHotKeyChange: (String) -> Void = { _ in }
    var onCallAudioSourceChange: (CallAudioSource) -> Void = { _ in }
    var onSourceSync: (String) async -> CorpusRunner.RunResult = { _ in
        .failed(L("The capture service is not available."))
    }
    var onReviewInterrupted: (String) -> Void = { _ in }
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
    var callAudioSource: CallAudioSource {
        didSet {
            guard callAudioSource != oldValue else { return }
            store.setSetting("call_audio_source", callAudioSource.rawValue)
            onCallAudioSourceChange(callAudioSource)
        }
    }
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
    /// Last real provider discovery result. Missing means unchecked, never ready.
    var providerHealth: [String: IntelligenceProbeState] = [:]
    var providerTesting: Set<String> = []
    var providerVerifiedAt: [String: Date] = [:]

    var configuredProviders: [IntelligenceProvider] {
        Self.configuredProviders(
            localProviderIDs: Set(localInstallations.map(\.providerID)),
            providerKeys: providerKeys
        )
    }

    nonisolated static func configuredProviders(
        localProviderIDs: Set<String>,
        providerKeys: [String: String]
    ) -> [IntelligenceProvider] {
        IntelligenceProvider.all.filter { provider in
            provider.isPrivate
                ? localProviderIDs.contains(provider.id)
                : !(providerKeys[provider.id] ?? "").isEmpty
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
            providerHealth[provider.id] = .needsSetup
            aiStatus = trimmed.isEmpty
                ? L("%@ key deleted.", provider.name)
                : L("%@ key saved to the Keychain.", provider.name)
            if !trimmed.isEmpty {
                Task { @MainActor in await self.refreshProviderHealth(providerIDs: [provider.id]) }
            }
        } catch {
            aiStatus = L("The Keychain refused the key: %@", String(describing: error))
        }
    }

    /// Asks the chosen model to say one word. The only way to know a key works is to use it.
    func testIntelligence() {
        guard let provider = IntelligenceProvider.named(aiProvider),
              configuredProviders.contains(where: { $0.id == provider.id }) else {
            let name = IntelligenceProvider.named(aiProvider)?.name ?? aiProvider
            aiStatus = L("%@ is not ready. Start the local server or save and verify its key.", name)
            return
        }
        Task { @MainActor in
            await testProvider(provider)
        }
    }

    func testProvider(_ provider: IntelligenceProvider) async {
        guard !providerTesting.contains(provider.id) else { return }
        providerTesting.insert(provider.id)
        defer { providerTesting.remove(provider.id) }
        providerHealth[provider.id] = .configured
        aiStatus = L("Testing %@…", provider.name)
        do {
            let adapter = BELHTTPModelProvider(descriptor: provider)
            let answer = try await adapter.generate(
                BELModelRequest(prompt: L("Reply with one word only: ready"),
                                sensitivity: .personal, maxTokens: 256),
                model: modelForProvider(provider)
            ).text
            providerHealth[provider.id] = .ready
            providerVerifiedAt[provider.id] = .now
            aiStatus = L("%@ connected: %@", provider.name, String(answer.prefix(40)))
        } catch let error as IntelligenceError {
            providerHealth[provider.id] = .offline(error.description)
            aiStatus = error.description
        } catch {
            providerHealth[provider.id] = .offline(error.localizedDescription)
            aiStatus = error.localizedDescription
        }
    }

    func modelForProvider(_ provider: IntelligenceProvider) -> String {
        selectedLocalModels[provider.id] ?? provider.defaultModel
    }

    /// Checks configured providers through their discovery endpoint. A saved key or a selected
    /// local model is not enough to paint a green status in Settings.
    func refreshProviderHealth(providerIDs: Set<String>? = nil) async {
        let providers = IntelligenceProvider.all.filter { provider in
            (providerIDs == nil || providerIDs?.contains(provider.id) == true)
                && (provider.isPrivate || !(providerKeys[provider.id] ?? "").isEmpty)
        }
        for provider in providers {
            let result = await IntelligenceProvider.probe(provider, key: providerKeys[provider.id])
            if result == .configured, providerHealth[provider.id] == .ready {
                continue
            }
            providerHealth[provider.id] = result
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
        Task { @MainActor in await refreshProviderHealth() }
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
        status = L("Configuration copied. Paste it into the Claude Desktop file.")
    }
    var license: LicenseIdentity?
    var licenseClient: LicenseClient?
    var licenseStatus: String?
    /// Set when a newer version is available, so the UI can offer a download button.
    var availableUpdate: Release?

    init(store: Store, appVersion: String, updateFeedURL: String?, loadSecureState: Bool = true) {
        self.store = store
        self.loadsSecureState = loadSecureState
        self.appVersion = appVersion
        self.updateFeedURL = updateFeedURL
        language = Language.resolve(stored: store.setting("ui_language"),
                                    systemPreferred: Locale.preferredLanguages)
        hotkey = store.setting("hotkey") ?? HotKey.Combo.all[0].label
        callAudioSource = CallAudioSource(rawValue: store.setting("call_audio_source") ?? "") ?? .automatic
        clipboardEnabled = store.setting("clipboard_enabled", default: true)
        retentionDays = store.setting("clipboard_retention_days", default: 30)
        maxItems = store.setting("clipboard_max_items", default: 500)
        updateCheckEnabled = store.setting("update_check_enabled", default: false)
        soundsEnabled = store.setting("sounds_enabled", default: true)
        soundsChrome = store.setting("sounds_chrome", default: false)
        graphEnabled = store.setting("graph_enabled", default: false)
        interfaceLanguage = Language(rawValue: store.setting("interface_language") ?? "")
            ?? Loc.language
        habitsEnabledSetting = store.setting("habits_enabled", default: false)
        learningEnabledSetting = store.setting("learning_enabled", default: false)
        aiProvider = store.setting("ai_provider") ?? "ollama"
        confidentialStaysLocal = store.setting("ai_confidential_local", default: true)
        pasteAfterCopy = store.setting("paste_after_copy", default: false) && Permissions.accessibilityGranted
        launchAtLogin = LaunchAtLogin.isEnabled
        reload()
        refreshNotificationPermission()
        // Reads the stored pause and puts the menu bar item up if there is one. Done here so a
        // pause survives a restart *visibly*: coming back from lunch to an app that is silently
        // still paused is the failure this whole panel is guarding against.
        refreshPrivacy()
    }

    func reload() {
        snippets = store.snippets()
        workflows = store.workflows()
        flows = store.flows()
        if loadsSecureState { secretNames = Keychain.names() }
        excludedApps = store.excludedApps().sorted()
        aliases = store.aliases().map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
        if loadsSecureState { loadProviderKeys() }
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
            exclusionNote = L("That was the last one on the list, so the factory ones come back. To exclude no app at all, leave one you never use.")
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
            try? store.installPack(pack, source: L("team: %@", bundle.team))
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
            text += L("Skipped because you already have one by that name:")
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
            status = L("There is nothing to share yet: no memories marked “shared”, no commands, no flows of your own.")
            return
        }
        guard let passphrase = askPassphrase(
            title: L("Team phrase"),
            message: L("The same one the rest of the team uses. We neither keep it nor see it: if it is lost, the package cannot be opened.")
        ) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = SafeFilename.make("brain-believe", extension: "belaunch")
        panel.message = L("Encrypted with the team phrase.")
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
            status = L("Exported %1$@ memories, %2$@ command(s) and %3$@ flow(s), all encrypted.",
                       String(shareable.count), String(sharedPacks.count), String(sharedFlows.count))
        } catch {
            status = L("It could not be exported: %@", String(describing: error))
        }
    }

    /// Imports a teammate's bundle. Everything arrives as a proposal, nothing is applied.
    func importTeamBundle() {
        guard let vault = try? Vault(root: Vault.defaultRoot()) else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.message = L("Pick the team's encrypted package.")
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }

        guard let passphrase = askPassphrase(
            title: L("Team phrase"),
            message: L("The phrase this package was encrypted with.")
        ) else { return }

        do {
            let bundle = try TeamBrain.open(data,
                                            with: TeamBrain.key(fromPassphrase: passphrase,
                                                                team: "believe"))
            let plan = TeamBrain.plan(bundle, against: vault.objects())
            for object in plan.added {
                _ = try? vault.propose(object, reason: L("From the team · %@", bundle.exportedBy))
            }
            for conflict in plan.conflicts {
                _ = try? vault.propose(conflict.incoming,
                                       reason: L("From the team · contradicts “%@”", conflict.existing.statement))
            }
            let commands = applyCommands(from: bundle)
            status = commands
                + L("%@ memories from the team are waiting for you to confirm them. Nothing applied itself.",
                    String(plan.added.count + plan.conflicts.count))
        } catch {
            status = "\(error)"
        }
    }

    private func askPassphrase(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("Continue"))
        alert.addButton(withTitle: L("Cancel"))
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
            status = L("I found no Alfred snippets on this Mac.")
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
        panel.message = L("Pick the file you exported from Raycast.")
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }

        let result = Importers.parseRaycastExport(data)
        let summary = store.apply(result)
        reload()
        status = L("Raycast: %1$@ snippets and %2$@ links", String(summary.addedSnippets), String(summary.addedWorkflows))
            + (summary.skipped > 0 ? ", \(summary.skipped) omitidos." : ".")
    }

    // MARK: - How much room the brain takes

    /// The file on disk, in words.
    var databaseSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(store.fileSize), countStyle: .file)
    }

    /// Whether the file is holding much more space than its contents need.
    ///
    /// The threshold is a ratio and a floor together, because either alone lies: a brand new brain
    /// is nearly all overhead and would look permanently bloated on ratio, and a large healthy
    /// brain would look broken on size. What matters is a file several times its own content, and
    /// big enough for that to be worth a person's attention.
    var isBloated: Bool { store.fileSize > 200_000_000 && store.fileSize > store.contentSize * 4 }

    /// Rewrites the database compactly and gives the space back.
    ///
    /// Deliberately a button rather than something done at launch. Compacting writes a second copy
    /// before replacing the first, and somebody whose disk filled up because of this is exactly the
    /// person who cannot spare it. Failing here must cost nothing: the original is untouched until
    /// the new one is complete.
    func compactDatabase() {
        status = L("Compacting…")
        do {
            let saved = try store.compact()
            status = L("Compacted: %@ freed.",
                       ByteCountFormatter.string(fromByteCount: Int64(saved), countStyle: .file))
        } catch {
            status = L("It could not be compacted: %@", error.localizedDescription)
        }
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
    var remindersGranted: Bool { reminders?.isAuthorised ?? false }
    var contactsGranted: Bool { contacts?.isAuthorised ?? false }
    var photosGranted: Bool { photos?.isAuthorised ?? false }
    var notificationsGranted = false

    /// Set by the app so Settings can ask for the calendar without owning EventKit.
    var calendar: CalendarAccess?
    var reminders: ReminderAccess?
    var contacts: ContactAccess?
    var photos: PhotoAccess?
    var onRequestNotifications: (() async -> Bool)?

    func requestCalendar() {
        Task { @MainActor in await requestCalendarAndRefresh() }
    }

    func requestCalendarAndRefresh() async {
        guard let calendar else { return }
        await calendar.requestAccessIfNeeded()
        calendar.refresh()
    }

    func requestReminders() {
        Task { @MainActor in await requestRemindersAndRefresh() }
    }

    func requestRemindersAndRefresh() async {
        guard let reminders else { return }
        await reminders.requestAccessIfNeeded()
        await reminders.refresh()
        sourceRefreshRevision += 1
    }

    func requestContacts() {
        Task { @MainActor in await requestContactsAndRefresh() }
    }

    func requestContactsAndRefresh() async {
        guard let contacts else { return }
        await contacts.requestAccessIfNeeded()
        await contacts.refresh()
        sourceRefreshRevision += 1
    }

    func requestPhotos() {
        Task { @MainActor in await requestPhotosAndRefresh() }
    }

    func requestPhotosAndRefresh() async {
        guard let photos else { return }
        await photos.requestAccessIfNeeded()
        photos.refresh()
        sourceRefreshRevision += 1
    }

    func requestNotifications() {
        guard let onRequestNotifications else { return }
        Task { @MainActor in
            notificationsGranted = await onRequestNotifications()
        }
    }

    func refreshNotificationPermission() {
        // UserNotifications requires an application bundle proxy. SwiftPM's test helper is not
        // one, and asking its singleton there raises an Objective-C exception before Swift can
        // catch it. The real `.app` path still refreshes the TCC state normally.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsGranted = [.authorized, .provisional]
                .contains(settings.authorizationStatus)
        }
    }

    // MARK: - Vault: the promises, made real

    /// Local models actually running, found by asking them. "Si tienes Ollama funciona" put the
    /// checking on the person who came here to not have to check.
    var localInstallations: [LocalModels.Installation] = []
    var localScanned = false

    func providerState(_ id: String) -> ModelProviderDescriptor.State? {
        guard let descriptor = ModelProviderRegistry.named(id) else { return nil }
        if let health = providerHealth[id] {
            switch health {
            case .ready: return .ready
            case .configured: return .needsSetup
            case .needsSetup: return .needsSetup
            case .offline: return .offline
            }
        }
        let configuredKeys = Set(providerKeys.compactMap { key, value in
            value.isEmpty ? nil : ModelProviderRegistry.named(key)?.keychainAccount
        })
        // Before a probe, configuration is deliberately inconclusive.
        if descriptor.isPrivate { return .offline }
        return configuredKeys.contains(descriptor.keychainAccount) ? .needsSetup : .needsSetup
    }

    func providerStatusText(_ id: String) -> String {
        switch providerHealth[id] {
        case .ready:
            let model = IntelligenceProvider.named(id).map(modelForProvider) ?? ""
            return L("Ready to answer with %@", model)
        case .configured: return L("Connection found. Run Test to verify a real answer.")
        case .offline(let reason): return reason
        case .needsSetup: return L("Save a key and verify the connection")
        case nil:
            return (providerKeys[id] ?? "").isEmpty
                ? L("No key saved") : L("Not verified yet")
        }
    }

    func scanLocalModels() {
        Task { @MainActor in
            localInstallations = await LocalModels.installed()
            localScanned = true
            // Pick one the person actually has. The app used to ask Ollama for a hardcoded
            // "llama3.2" whether or not it was installed, which is what made translating hang.
            for installation in localInstallations {
                let key = "ai_model_\(installation.providerID)"
                let saved = store.setting(key) ?? ""
                if let selected = LocalModels.selectedModel(in: installation, saved: saved) {
                    store.setSetting(key, selected)
                }
            }
            selectedLocalModels = Dictionary(uniqueKeysWithValues: localInstallations.map {
                ($0.providerID, LocalModels.selectedModel(
                    in: $0, saved: store.setting("ai_model_\($0.providerID)")) ?? $0.models[0])
            })
            await refreshProviderHealth()
        }
    }

    /// Which model each running local runner should be asked for.
    var selectedLocalModels: [String: String] = [:]

    func chooseLocalModel(_ model: String, for providerID: String) {
        store.setSetting("ai_model_\(providerID)", model)
        selectedLocalModels[providerID] = model
        providerHealth[providerID] = .configured
        providerVerifiedAt[providerID] = nil
    }

    var vaultRoot: String { Vault.defaultRoot() }

    // "Open in Obsidian" and "turn the vault into a git repository" used to live here. Both are
    // gone: the brain is what this product sells, and a button that hands the corpus to another
    // note-taking app — or sets up the sync we intend to charge for — sends people out of the door
    // we are trying to get them through. The vault is still an ordinary folder of .md files on
    // disk, so anyone who wants either can do it themselves; the app just does not offer it.

    func rebuildVaultStructure() {
        do {
            let created = try VaultGuide.scaffold(at: vaultRoot)
            status = created.isEmpty
                ? L("The structure was already complete.")
                : "Creado: " + created.joined(separator: ", ")
        } catch {
            status = L("The structure could not be made: %@", error.localizedDescription)
        }
    }

    // MARK: - What it watches, and what it learned

    /// Two separate switches on purpose. Someone may want the graph that answers "what was I doing
    /// before the call" without wanting the app to propose new commands, and the reverse.
    var graphEnabled: Bool {
        didSet { store.setSetting("graph_enabled", graphEnabled) }
    }
    /// The language the interface is drawn in.
    ///
    /// There was no way to choose it and nothing remembered the choice, so the app took whatever
    /// the system said. On a Mac set to English that produced neither language: the strings that
    /// go through the catalog came out in English and the ones still written by hand stayed in
    /// Spanish, in the same window.
    var interfaceLanguage: Language {
        didSet {
            store.setSetting("interface_language", interfaceLanguage.rawValue)
            Loc.language = interfaceLanguage
        }
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
        status = L("Action history cleared.")
    }

    func clearGraph() {
        store.clearWorkGraph()
        reloadIntelligenceExtras()
        status = L("Working memory cleared.")
    }

    func forget(_ trait: Trait) {
        store.forgetTrait(trait.name)
        reloadIntelligenceExtras()
    }

    func forgetEverythingLearned() {
        store.forgetAllTraits()
        reloadIntelligenceExtras()
        status = L("Everything it learned about how you work has been forgotten.")
    }

    func removePack(_ pack: OutcomePack) {
        store.removePack(id: pack.id)
        reloadIntelligenceExtras()
    }

    /// Exports the installed outcomes so a team can share the same commands.
    func exportPacks() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "comandos-belauncher.json"
        panel.message = L("Share your commands with the team.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try OutcomePack.encode(store.installedPacks()).write(to: url)
            status = "Comandos exportados."
        } catch {
            status = L("They could not be exported: %@", error.localizedDescription)
        }
    }

    func importPacks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = L("Import shared commands.")
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
                ? L("%@ command(s) installed.", String(installable.count))
                : L("%1$@ installed. %2$@ skipped because you already have a command by that name.",
                    String(installable.count), String(conflicts.count))
        } catch {
            status = "\(error)"
        }
    }

    // MARK: - Connecting the assistant you already use

    var mcpConnections: [String: Bool] = [:]

    func refreshMCPConnections() {
        mcpConnections = Dictionary(uniqueKeysWithValues: MCPClient.all.map { client in
            let data = FileManager.default.contents(atPath: client.absoluteConfigPath())
            return (client.id, MCPSetup.isCurrent(data, client: client,
                                                  executablePath: mcpExecutablePath))
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
    var corpusPhase = "idle"
    var corpusRunSource = "corpus"
    var corpusLastRun: Date?
    var corpusLastWritten = 0
    var corpusLastProblem: String?
    var corpusHasCheckpoint = false
    var corpusRunHistory: [CorpusRunRecord] = []
    var ingestionProgress: IngestionProgress?
    var actionRuns: [ActionRunSnapshot] = []
    var interruptedActionRuns: [ActionRunSnapshot] = []
    var recentActionRuns: [ActionRunSnapshot] { Array(actionRuns.prefix(6)) }
    var startupReadyMS: Int?

    var corpusStatusLine: String {
        let written = L("%@ passages written", String(corpusLastWritten))
        let scope: String? = corpusRunSource == "corpus" || corpusRunSource.isEmpty
            ? nil : corpusSourceLabel(corpusRunSource)
        switch corpusPhase {
        case "waiting": return L("Capture is waiting for its next background pass.")
        case "gathering":
            return scope.map { L("Capture is reading %@…", $0) }
                ?? L("Capture is reading permitted sources…")
        case "assembling":
            return scope.map { L("Capture is assembling %@ into the Brain…", $0) }
                ?? L("Capture is assembling the Brain…")
        case "writing":
            return scope.map { L("Capture is writing %@: %@.", $0, written) }
                ?? L("Capture is writing %@.", written)
        case "completed": return L("Last capture completed: %@.", written)
        case "paused": return L("Capture is paused. Nothing is being read.")
        case "deferred": return L("Background capture is deferred while the Mac is conserving resources.")
        case "failed": return L("Last capture needs attention.")
        default: return L("Capture has not run yet.")
        }
    }
    /// Set when the numbers could not be read at all. Distinct from "there is nothing indexed":
    /// one of them is an empty brain and the other is a broken panel, and showing zeros for the
    /// second is how somebody concludes their notes disappeared.
    var brainError: String?
    var brainCards: [PrivacyCopy.Brain.Card] = []
    var brainIsLocal = true

    func sourceEnabled(_ id: String) -> Bool {
        store.setting("source_enabled_\(id)", default: true)
    }

    func setSourceEnabled(_ id: String, _ enabled: Bool) {
        store.setSetting("source_enabled_\(id)", enabled)
        sourceRefreshRevision &+= 1
    }

    func syncSource(_ id: String) {
        let supported = ["apple-mail", "messages", "notes", "browsers", "conversations"]
        guard supported.contains(id), sourceEnabled(id), !sourceSyncing.contains(id) else { return }
        Task { @MainActor in
            sourceSyncing.insert(id)
            sourceRefreshRevision &+= 1
            let result = await onSourceSync(id)
            sourceFeedback[id] = sourceMessage(result)
            sourceFeedbackErrors[id] = if case .failed = result { true } else { false }
            sourceSyncing.remove(id)
            sourceRefreshRevision &+= 1
            refreshBrainState()
        }
    }

    func syncAllSources() {
        guard sourceSyncing.isEmpty else { return }
        Task { @MainActor in
            sourceSyncing.insert("all")
            sourceRefreshRevision &+= 1
            let result = await onSourceSync("all")
            sourceFeedback["all"] = sourceMessage(result)
            sourceFeedbackErrors["all"] = if case .failed = result { true } else { false }
            sourceSyncing.remove("all")
            sourceRefreshRevision &+= 1
            refreshBrainState()
        }
    }

    var sourceRefreshRevision = 0
    var sourceSyncing: Set<String> = []
    var sourceFeedback: [String: String] = [:]
    var sourceFeedbackErrors: [String: Bool] = [:]

    private func sourceMessage(_ result: CorpusRunner.RunResult) -> String {
        switch result {
        case .completed(let written): return L("Read completed · %@ new passages", String(written))
        case .paused: return L("Capture is paused. Nothing was read.")
        case .deferred(let reason): return L("Capture was deferred: %@", reason)
        case .busy: return L("Another source is already being read.")
        case .failed(let problem): return L("Read failed: %@", problem)
        }
    }

    func sourceIsSyncing(_ id: String) -> Bool {
        sourceSyncing.contains(id) || sourceSyncing.contains("all")
    }

    func corpusSourceLabel(_ id: String?) -> String {
        switch id {
        case "apple-mail": return L("Apple Mail")
        case "messages": return L("Apple Messages")
        case "notes": return L("Apple Notes")
        default: return L("All sources")
        }
    }

    func reviewInterrupted(_ id: String) {
        onReviewInterrupted(id)
    }

    func sourceStatusLine(_ id: String) -> String? {
        guard sourceEnabled(id) else { return L("Paused by you") }
        if let feedback = sourceFeedback[id] { return feedback }
        guard let raw = store.setting("source_last_sync_\(id)"),
              let timestamp = Double(raw), timestamp > 0 else { return L("Not read yet") }
        let count = store.setting("source_last_count_\(id)") ?? "0"
        if let problem = store.setting("source_last_problem_\(id)"), !problem.isEmpty {
            if let retry = Double(store.setting("source_retry_after_\(id)") ?? ""),
               retry > Date.now.timeIntervalSince1970 {
                let date = Date(timeIntervalSince1970: retry)
                return L("Retry after %@ · needs attention", date.formatted(date: .omitted, time: .shortened))
            }
            return L("Last read: %@ items · needs attention", count)
        }
        let date = Date(timeIntervalSince1970: timestamp)
        return L("Last read: %@ items · %@", count, date.formatted(date: .abbreviated, time: .shortened))
    }

    /// A catalog entry is not proof that this Mac has actually read the source. The source
    /// center uses this to keep its green state tied to a completed, error-free sync.
    func sourceHasSuccessfulSync(_ id: String) -> Bool {
        LocalSourceHealth.successfulSync(id, store: store)
    }

    /// The browser connector has no separate schedule record: its evidence is the local history
    /// database that the next corpus pass will read. Do not show Safari as connected on a Mac
    /// where no readable browser history exists.
    func browserSourceAvailable() -> Bool {
        LocalSourceHealth.browserAvailable()
    }

    func clipboardHasEvidence() -> Bool {
        clipboardEnabled && !store.clips(limit: 1).isEmpty
    }

    private func brainForReading() -> BrainSearch {
        if let brain { return brain }
        let made = BrainSearch(store: store)
        brain = made
        return made
    }

    func refreshBrainState() {
        brainError = nil
        brainReadout = nil
        corpusPhase = store.setting("corpus_run_phase") ?? "idle"
        corpusRunSource = store.setting("corpus_run_source") ?? "corpus"
        corpusLastRun = store.setting("corpus_last_run").flatMap { Date(timeIntervalSince1970: Double($0) ?? 0) }
        corpusLastWritten = Int(store.setting("corpus_last_passages") ?? "0") ?? 0
        corpusLastProblem = store.setting("corpus_last_problem")
        corpusRunHistory = store.setting("corpus_run_history")
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([CorpusRunRecord].self, from: $0) } ?? []
        ingestionProgress = store.setting("corpus_ingestion_progress")
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(IngestionProgress.self, from: $0) }
        actionRuns = store.actionRuns(limit: 50)
        interruptedActionRuns = actionRuns.filter { $0.state == .interrupted }
        corpusHasCheckpoint = store.setting("corpus_checkpoint")
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(IngestionCheckpoint.self, from: $0) }
            .map { !$0.completed } ?? false
        startupReadyMS = store.setting("startup_launcher_ready_ms").flatMap(Int.init)
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
                self.brainStatus = L("Index rebuilt. With no model, it searches for exact words.")
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
                self.brainStatus = L("The model stopped answering halfway. What was indexed stays: press again and it carries on from where it was.")
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
                updateStatus = L("No update feed is configured.")
            case .upToDate:
                updateStatus = L("You are on the latest version (%@).", version)
            case .available(let release):
                availableUpdate = release
                updateStatus = L("There is a new version: %@", release.version)
            case .unavailable(let reason):
                updateStatus = L("We could not check for updates: %@", reason)
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
                licenseStatus = L("We could not deactivate right now. Try again in a moment.")
                return
            }
            LicenseVault.clear()
            licenseStatus = L("Mac released.")
            NSApp.terminate(nil)
        }
    }

    private func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }
}
