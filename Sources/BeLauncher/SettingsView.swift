import SwiftUI
import AppKit
import BeLauncherCore

/// Settings, organised by what the user is trying to do.
///
/// It used to be one long scrolling form that grew a section per release. That is how features end
/// up existing in code and nowhere else: choosing an AI model, excluding an app from the clipboard,
/// seeing your aliases and connecting the brain to Claude were all implemented and all unreachable.
/// Tabs are not decoration here — they are what makes the app honest about what it can do.
@MainActor
struct SettingsView: View {
    @Bindable var model: SettingsModel

    /// The sections, each with a line saying what it is for.
    ///
    /// This used to be a `TabView`. With seven tabs and a window this size, SwiftUI hid the ones
    /// that did not fit behind a `»` button in the corner: an unlabelled chevron that nobody reads
    /// as "there are four more sections in here". A sidebar shows all seven at once and has room
    /// for a subtitle, which is where most of the "what is this even for" went.
    enum Section: String, CaseIterable, Identifiable {
        case general, intelligence, voice, clipboard, commands, agents, memory, privacy, content, brain,
             data
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: L("General")
            case .intelligence: L("Intelligence")
            case .voice: L("Voice and calls")
            case .clipboard: L("Clipboard")
            case .commands: L("What I can type")
            case .agents: L("Errands")
            case .memory: L("What it watches")
            case .privacy: L("Privacy")
            case .content: L("My shortcuts")
            case .brain: L("My brain")
            case .data: L("Data")
            }
        }

        var subtitle: String {
            switch self {
            case .general: L("Shortcut, startup, licence")
            case .intelligence: L("Which model answers, and with whose key")
            case .voice: L("Voice notes, dictation and calls")
            case .clipboard: L("What gets saved and what does not")
            case .commands: L("Everything the window understands")
            case .agents: L("“/” commands and missions in flight")
            case .memory: L("History, working memory and what it learned")
            case .privacy: L("Pause, exclude, forget")
            case .content: L("Snippets, flows, aliases, secrets")
            case .brain: L("Where your notes live and who can read them")
            case .data: L("Export, import, uninstall")
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .intelligence: "sparkles"
            case .voice: "mic"
            case .clipboard: "doc.on.clipboard"
            case .commands: "command"
            case .agents: "terminal"
            case .memory: "eye"
            case .privacy: "hand.raised"
            case .content: "text.quote"
            case .brain: "brain"
            case .data: "lock.shield"
            }
        }
    }

    @State private var selection: Section = .general

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                NavigationLink(value: section) {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.title)
                            Text(section.subtitle)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    } icon: {
                        Image(systemName: section.symbol).foregroundStyle(Theme.accent)
                    }
                    .padding(.vertical, 3)
                }
            }
            .navigationSplitViewColumnWidth(232)
        } detail: {
            Group {
                switch selection {
                case .general: GeneralTab(model: model)
                case .intelligence: IntelligenceTab(model: model)
                case .voice: VoiceTab(model: model)
                case .clipboard: ClipboardTab(model: model)
                case .commands: CommandsTab()
                case .agents: AgentsTab(model: model)
                case .memory: MemoryTab(model: model)
                case .privacy: PrivacyView(model: model)
                case .content: ContentTab(model: model)
                case .brain: BrainTab(model: model)
                case .data: DataTab(model: model)
                }
            }
            .navigationTitle(selection.title)
        }
        // Ideal rather than fixed, so the layout follows the window the day it can be resized.
        // Everything inside reflows: the counts are an adaptive grid and the button rows wrap.
        .frame(minWidth: 760, idealWidth: 860, minHeight: 540, idealHeight: 620)
        .onAppear {
            model.reload(); model.scanLocalModels(); model.reloadIntelligenceExtras()
            openRequestedSection()
        }
        // The window is reused rather than rebuilt, so `onAppear` fires once in its whole life.
        // Without this, asking for a panel from outside only worked the first time.
        .onChange(of: model.requestedSection) { _, _ in openRequestedSection() }
    }

    private func openRequestedSection() {
        guard let requested = model.requestedSection,
              let section = Section(rawValue: requested) else { return }
        selection = section
        model.requestedSection = nil
    }
}

// MARK: - General

@MainActor
private struct GeneralTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                // Each language written in itself. "Spanish" in an English list is a small tell
                // that the product was translated rather than made for the person reading it.
                Picker(L("Language"), selection: $model.language) {
                    ForEach(Language.allCases, id: \.self) { Text($0.endonym).tag($0) }
                }
                Text(L("Only what the app says to you. What you have saved keeps whatever language it was written in, and search still works across both."))
                    .font(.caption).foregroundStyle(.secondary)

                Picker(L("Global shortcut"), selection: $model.hotkey) {
                    ForEach(HotKey.Combo.all, id: \.label) { Text($0.label).tag($0.label) }
                }
                LabeledContent(L("Clipboard"), value: "⌥C")
                Toggle(L("Open BeLauncher at login"), isOn: $model.launchAtLogin)
                if let error = model.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }

            Section(L("Sound")) {
                Toggle(L("Make a sound when you copy"), isOn: $model.soundsEnabled)
                Text(L("It sounds every time you copy anything, in any app: that is the confirmation it was kept. **If it stays quiet, it was not kept** — a password, or something shaped like a key. The silence says something too."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(L("Also when the window opens and closes"), isOn: $model.soundsChrome)
                    .disabled(!model.soundsEnabled)
                Text(L("Off on purpose: copying happens dozens of times a day and opening the window happens hundreds. Try it and decide."))
                    .font(.caption).foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    ForEach(Sound.Cue.allCases, id: \.self) { cue in
                        Button(cue.label) { model.preview(cue) }
                            .controlSize(.small)
                    }
                }
                Text(L("The sounds are generated inside the app rather than played from files, which is why they sound like no other Mac you have used."))
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Section(L("Updates")) {
                Toggle(L("Check for updates"), isOn: $model.updateCheckEnabled)
                UpdateRow(model: model)
                Text(L("BeLauncher has no account, no analytics and no server. It only looks for a new version when you ask it to, and installs it itself: no dragging the app over the old one."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Licencia") {
                if let license = model.license {
                    LabeledContent(L("Email"), value: license.email)
                    LabeledContent(L("Key")) {
                        Text(model.maskedKey).font(.system(.caption, design: .monospaced))
                    }
                    LabeledContent(L("This Mac"), value: DeviceIdentity.name)
                    Button(L("Deactivate this Mac")) { model.deactivateThisMac() }
                } else {
                    Text(L("No active licence.")).font(.caption).foregroundStyle(.secondary)
                }
                if let status = model.licenseStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent(L("Version"), value: model.appVersion)
            }
        }
        .formStyle(.grouped)
    }
}

/// The update, as one row that always says exactly where it is.
///
/// Every state is named: nothing to do, something to install, working on it, done and waiting for
/// you, or a failure you can read. A progress bar that can only spin is how people end up force
/// quitting halfway through a replace.
@MainActor
private struct UpdateRow: View {
    @Bindable var model: SettingsModel

    var body: some View {
        switch model.updater.phase {
        case .idle:
            HStack {
                Button(L("Check now")) { model.checkForUpdates() }
                    .disabled(!model.updateCheckEnabled)
                if let release = model.availableUpdate {
                    Button("Actualizar a \(release.version)") { model.installUpdate() }
                        .buttonStyle(.borderedProminent)
                }
                if let status = model.updateStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

        case .downloading(let fraction):
            HStack {
                ProgressView(value: fraction).frame(width: 150)
                Text(L("Downloading…")).font(.caption).foregroundStyle(.secondary)
                Button(L("Cancel")) { model.updater.cancel() }.controlSize(.small)
            }

        case .verifying:
            Label(L("Checking Apple's signature…"), systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)

        case .installing:
            Label(L("Installing…"), systemImage: "arrow.down.app")
                .font(.caption).foregroundStyle(.secondary)

        case .readyToRelaunch(let version):
            HStack {
                Label(L("Done: %@ is installed.", version), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                Spacer()
                Button("Reiniciar ahora") { model.updater.relaunch() }
                    .buttonStyle(.borderedProminent)
            }

        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Text(reason).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                HStack {
                    Button(L("Try again")) { model.installUpdate() }.controlSize(.small)
                    if let release = model.availableUpdate, let url = URL(string: release.url) {
                        Button("Descargar a mano") { NSWorkspace.shared.open(url) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

// MARK: - Intelligence

@MainActor
private struct IntelligenceTab: View {
    @Bindable var model: SettingsModel
    @State private var draftKeys: [String: String] = [:]

    var body: some View {
        Form {
            Section(L("Which model answers")) {
                Picker("Preferido", selection: $model.aiProvider) {
                    ForEach(IntelligenceProvider.all) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }
                Toggle(L("Confidential things never leave the Mac"), isOn: $model.confidentialStaysLocal)
                Text(L("With this on, pulling tasks out of a meeting or anything marked as company material only goes to a local model. If there is none, it refuses rather than sending it anyway."))
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button("Probar") { model.testIntelligence() }
                    if let status = model.aiStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section(L("Your keys")) {
                ForEach(IntelligenceProvider.all.filter { !$0.isPrivate }) { provider in
                    HStack {
                        Text(provider.name).frame(width: 100, alignment: .leading)
                        SecureField(L("key"), text: Binding(
                            get: { draftKeys[provider.id] ?? model.providerKeys[provider.id] ?? "" },
                            set: { draftKeys[provider.id] = $0 }
                        ))
                        Button(L("Save")) {
                            model.saveKey(draftKeys[provider.id] ?? "", for: provider)
                            draftKeys[provider.id] = nil
                        }
                        .controlSize(.small)
                        if !(model.providerKeys[provider.id] ?? "").isEmpty {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.system(size: 11))
                        }
                    }
                }
                Text(L("The keys go into your Keychain and the requests leave your Mac straight for the provider: nothing passes through Believe and you pay whoever you choose. They are never included in an export."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Models on your Mac")) {
                if !model.localScanned {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Buscando modelos locales…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if model.localInstallations.isEmpty {
                    Text(LocalModels.howToGetOne)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("Open ollama.com")) {
                        if let url = URL(string: "https://ollama.com") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } else {
                    ForEach(model.localInstallations) { installation in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(L("%@ is running", installation.name),
                                  systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.system(size: 12))
                            Picker(L("Model"), selection: Binding(
                                get: { model.selectedLocalModels[installation.providerID]
                                        ?? installation.models[0] },
                                set: { model.chooseLocalModel($0, for: installation.providerID) }
                            )) {
                                ForEach(installation.models, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    }
                    Text(L("No key, no cost per token, and nothing leaves this Mac."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(L("Look again")) { model.scanLocalModels() }
                    .controlSize(.small)
            }

            Section(L("What you can ask it for")) {
                ForEach(AIVerb.all) { verb in
                    HStack {
                        Image(systemName: verb.symbol).foregroundStyle(Theme.accent).frame(width: 16)
                        Text(verb.title).font(.system(size: 12))
                        Spacer()
                        if verb.sensitivity == .confidential {
                            Text(L("local only")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(L("They appear with ⌘K over any text in the clipboard."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Clipboard

@MainActor
private struct ClipboardTab: View {
    @Bindable var model: SettingsModel
    @State private var newExclusion = ""

    var body: some View {
        Form {
            Section {
                Toggle(L("Keep what you copy"), isOn: $model.clipboardEnabled)
                Stepper(L("Delete after %@ days", String(model.retentionDays)),
                        value: $model.retentionDays, in: 1...365)
                Stepper(L("Keep at most %@", String(model.maxItems)),
                        value: $model.maxItems, in: 20...5000, step: 20)
                Toggle(L("Paste into the previous app when you pick"), isOn: $model.pasteAfterCopy)
                Button(L("Clear the history")) {
                    model.store.clearClips()
                    model.status = "Historial borrado."
                }
            }

            Section("Apps excluidas") {
                if model.excludedApps.isEmpty {
                    Text(L("None. Whatever you copy from any app gets kept."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.excludedApps, id: \.self) { app in
                    HStack {
                        Text(app)
                        Spacer()
                        Button {
                            model.removeExcludedApp(app)
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField(L("App name"), text: $newExclusion)
                    Button("Excluir") {
                        model.addExcludedApp(newExclusion)
                        newExclusion = ""
                    }
                    .controlSize(.small)
                }
                if !model.seenApps.isEmpty {
                    Text(L("Seen lately: ") + model.seenApps.prefix(6).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Text(L("Copies that password managers mark as confidential are never kept, nor is anything shaped like a credential. This is for whatever else you would rather leave out."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Commands

/// The catalogue. Without it, everything the app can do is a guessing game: system commands,
/// window layouts and missions were all searchable and none of them discoverable.
@MainActor
private struct CommandsTab: View {
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filtrar", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(10)

            List {
                Section(L("Type an intent")) {
                    ForEach(MissionPlanner.outcomes.filter { matches($0.title) }) { outcome in
                        row(outcome.title, hint: outcome.triggers.first ?? "",
                            symbol: "wand.and.stars")
                    }
                }

                Section(L("Give it something to do (type “/”)")) {
                    ForEach(OutcomePack.builtIn.filter { matches($0.name) }) { pack in
                        row(pack.name, hint: "/\(pack.verb)", symbol: pack.symbol)
                    }
                }

                Section(L("Working memory")) {
                    row(L("What we promised somebody"), hint: L("what did we promise Andrés"),
                        symbol: "hand.raised")
                    row(L("Open the latest from a project"), hint: L("open the latest from Atlas"),
                        symbol: "clock.arrow.circlepath")
                    row(L("Pick up where you were before the call"),
                        hint: L("pick up what I was doing"), symbol: "arrow.uturn.backward")
                    row(L("Who somebody is"), hint: L("who is Acme"), symbol: "person.text.rectangle")
                }

                Section(L("Ask your brain")) {
                    row(L("What we decided about something"), hint: L("what did we decide about pricing"),
                        symbol: "brain")
                    row(L("Get me ready for a meeting"), hint: L("get me ready for Acme"),
                        symbol: "person.2")
                    row("Recordar algo", hint: L("remember that…"), symbol: "text.badge.plus")
                    row(L("What is slipping"), hint: "pulse", symbol: "waveform.path.ecg")
                }

                Section(L("System")) {
                    ForEach(SystemCommand.all.filter { matches($0.title) }) { command in
                        row(command.title, hint: command.keywords.first ?? "",
                            symbol: command.symbol)
                    }
                }

                Section(L("Windows")) {
                    ForEach(WindowCommand.all.filter { matches($0.title) }) { command in
                        row(command.title, hint: command.keywords.first ?? "",
                            symbol: command.symbol)
                    }
                }

                Section("Utilidades") {
                    row(L("See what is eating the Mac"), hint: "cpu · memoria", symbol: "gauge.with.needle")
                    row(L("Close an app that hung"), hint: "cpu chrome", symbol: "xmark.octagon")
                    row(L("Keep the Mac awake"), hint: "cafeina · cafeina 2 horas",
                        symbol: "cup.and.saucer")
                    row(L("Jot something down fast"), hint: L("note call Andrés"), symbol: "square.and.pencil")
                    row(L("Save where every window is"), hint: L("save workspace"),
                        symbol: "rectangle.3.group")
                    row("Volver a ese reparto", hint: "espacio trabajo · espacios",
                        symbol: "arrow.uturn.backward.square")
                    row("Calcular", hint: "2+2 · 15% of 300", symbol: "equal.square")
                    row("Convertir", hint: "10 km to mi", symbol: "arrow.left.arrow.right")
                    row(L("Find files"), hint: "f informe", symbol: "doc")
                    row(L("Go to a path"), hint: "/Users/… · ~/Desktop · Tab completa",
                        symbol: "arrow.right.doc.on.clipboard")
                    row(L("Search Google, Claude, ChatGPT…"), hint: "g · c · gpt", symbol: "link")
                    row("Traducir, resumir, corregir…", hint: "traducir · resume · corrige",
                        symbol: "sparkles")
                    row(L("Read what is on screen"), hint: "⌥⇧Espacio",
                        symbol: "rectangle.dashed.badge.record")
                }
            }
            .listStyle(.inset)
        }
    }

    private func matches(_ title: String) -> Bool {
        filter.isEmpty || title.localizedCaseInsensitiveContains(filter)
    }

    private func row(_ title: String, hint: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 16)
            Text(title).font(.system(size: 12))
            Spacer()
            Text(hint)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Voice

@MainActor
private struct VoiceTab: View {
    @Bindable var model: SettingsModel
    @State private var qwen = QwenASRInstaller()
    @State private var microphoneGranted = Permissions.microphoneGranted
    @StateObject private var callDetector = CallAppDetector()

    var body: some View {
        Form {
            Section(L("Voice notes and dictation")) {
                Label(L("Record from any app with ⌥⌘V. Qwen runs in a separate local process; the launcher stays instant."),
                      systemImage: "mic")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent(L("Microphone")) {
                    Label(microphoneGranted ? L("Ready") : L("Permission needed"),
                          systemImage: microphoneGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(microphoneGranted ? .green : .orange)
                }
                Button {
                    Task { microphoneGranted = await Permissions.requestMicrophone() }
                } label: {
                    Label(L("Allow microphone"), systemImage: "mic.badge.plus")
                }
                .disabled(microphoneGranted)
            }

            Section(L("Qwen3-ASR · MLX")) {
                Picker(L("Model"), selection: $qwen.selectedModel) {
                    Text(L("0.6B · Fast")).tag(QwenASRInstaller.smallModel)
                    Text(L("1.7B · High quality")).tag(QwenASRInstaller.largeModel)
                }
                .disabled(qwen.isInstalling)

                Text(status)
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if qwen.isInstalling {
                        ProgressView().controlSize(.small)
                        Button { qwen.cancel() } label: {
                            Label(L("Cancel"), systemImage: "xmark")
                        }
                    } else {
                        Button {
                            qwen.install()
                        } label: {
                            Label(qwen.isReady ? L("Reinstall model") : L("Download Qwen3-ASR"),
                                  systemImage: qwen.isReady ? "arrow.clockwise" : "arrow.down.circle")
                        }
                    }
                }
            }

            Section(L("Shortcuts")) {
                shortcutRow(L("Voice note"), key: "⌥⌘V", symbol: "waveform")
                shortcutRow(L("Dictation"), key: "⌥⌘D", symbol: "text.cursor")
                shortcutRow(L("Call recording"), key: "⌥⌘C", symbol: "phone.badge.waveform")
                Text(L("The same capture engine will handle dictation and call recording. Nothing listens until you start it."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Call audio")) {
                Picker(L("Capture source"), selection: $model.callAudioSource) {
                    ForEach(CallAudioSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                if model.callAudioSource == .automatic, let app = callDetector.suggestedAppName {
                    Label(L("Suggested source: %@", app), systemImage: "sparkles")
                        .font(.caption).foregroundStyle(Theme.accent)
                }
                LabeledContent(L("Microphone"), value: microphoneGranted ? L("Ready") : L("Permission needed"))
                LabeledContent(L("System audio"), value: SystemAudioCapture.permissionGranted ? L("Ready") : L("Permission needed"))
                Text(L("Call recording needs Screen Recording permission to capture the other participants. Audio is kept as separate local evidence."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            qwen.refresh()
            microphoneGranted = Permissions.microphoneGranted
            callDetector.start()
        }
    }

    private func shortcutRow(_ title: String, key: String, symbol: String) -> some View {
        LabeledContent {
            Text(key).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private var status: String {
        switch qwen.phase {
        case .unknown: return L("Checking local ASR…")
        case .unavailable: return L("Qwen ASR needs an Apple Silicon Mac.")
        case .notInstalled: return L("Not installed. Apple Speech remains available as a fallback.")
        case .installing: return L("Installing the local runtime and downloading model weights…")
        case .ready: return L("Ready. Audio stays on this Mac.")
        case .failed(let message): return L("Qwen ASR could not be installed: %@", message)
        }
    }
}

// MARK: - Content

@MainActor
private struct ContentTab: View {
    @Bindable var model: SettingsModel

    @State private var snippetKeyword = ""
    @State private var snippetTitle = ""
    @State private var snippetBody = ""
    @State private var workflowKeyword = ""
    @State private var workflowTitle = ""
    @State private var workflowTemplate = ""

    var body: some View {
        Form {
            Section("Snippets") {
                if model.snippets.isEmpty {
                    Text(L("None yet.")).font(.caption).foregroundStyle(.secondary)
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
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
                Divider()
                TextField(L("Keyword"), text: $snippetKeyword)
                TextField(L("Name"), text: $snippetTitle)
                TextField("Texto", text: $snippetBody, axis: .vertical).lineLimit(2...5)
                if let error = model.snippetError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text(L("Tokens: {clipboard} {date} {time} {uuid} {cursor} {secret:NAME}"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Add")) {
                        if model.addSnippet(keyword: snippetKeyword, title: snippetTitle,
                                            body: snippetBody) {
                            snippetKeyword = ""; snippetTitle = ""; snippetBody = ""
                        }
                    }
                }
            }

            Section("Flujos") {
                FlowEditor(model: model)
            }

            Section("Workflows") {
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
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
                Divider()
                TextField(L("Keyword"), text: $workflowKeyword)
                TextField(L("Name"), text: $workflowTitle)
                TextField(L("URL template"), text: $workflowTemplate,
                          prompt: Text("https://example.com/search?q={query}"))
                if let error = model.workflowError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text(L("Only http, https and mailto. BeLauncher never runs scripts."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Add")) {
                        if model.addWorkflow(keyword: workflowKeyword, title: workflowTitle,
                                             template: workflowTemplate) {
                            workflowKeyword = ""; workflowTitle = ""; workflowTemplate = ""
                        }
                    }
                }
            }

            Section("Alias") {
                if model.aliases.isEmpty {
                    Text(L("None. You can make one with ⌘K over any app."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.aliases, id: \.alias) { entry in
                    HStack {
                        Text(entry.alias)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 90, alignment: .leading)
                        Text((entry.target as NSString).lastPathComponent)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button {
                            model.removeAlias(entry.alias)
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Section("Secretos (Llavero)") {
                ForEach(model.secretNames, id: \.self) { name in
                    HStack {
                        Label(name, systemImage: "key.fill")
                        Spacer()
                        Button {
                            Keychain.delete(name)
                            model.reload()
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField(L("Name"), text: $secretName)
                    SecureField("Valor", text: $secretValue)
                    Button(L("Save")) {
                        if model.addSecret(name: secretName, value: secretValue) {
                            secretName = ""; secretValue = ""
                        }
                    }
                }
                if let error = model.secretError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Text(L("Use them in snippets or workflows as {secret:NAME}. They are never exported."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @State private var secretName = ""
    @State private var secretValue = ""
}

// MARK: - Brain

@MainActor
private struct BrainTab: View {
    @Bindable var model: SettingsModel

    /// Written here rather than in the README alone: the folder explains the structure, this
    /// explains how anything ever gets into it.
    static let howItFills: [(type: String, does: String)] = [
        (L("remember that …"), L("It offers to keep something. You confirm.")),
        ("capturar reunion", L("With your notes on the clipboard, it pulls out decisions and commitments.")),
        (L("what did we decide about …"), L("What still stands today, not everything that was said.")),
        (L("get me ready for …"), L("Gathers what you know about somebody before you see them.")),
        ("pulse", L("What is going stale: contradictions, overdue things, nothing reviewed.")),
    ]

    /// Its own installer rather than the setup window's: someone can open Ajustes with that
    /// window closed and still start the download from here.
    @State private var installer = ModelInstaller()

    var body: some View {
        Form {
            Section(L("Brain status")) {
                BrainStatusView(model: model, installer: installer)
            }

            Section(L("How your brain fills up")) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(BrainTab.howItFills, id: \.type) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Text(item.type)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.cyan)
                                .frame(width: 175, alignment: .leading)
                            Text(item.does).font(.system(size: 11.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text(L("Nothing goes in without you confirming it. A brain that writes itself is a brain you cannot trust."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Where it lives")) {
                LabeledContent(L("Folder")) {
                    Text(model.vaultRoot).font(.caption).textSelection(.enabled).lineLimit(2)
                }
                Text(L("Seven folders already made, each with a note saying what goes inside, and a read-me that explains the whole thing. Open it whenever you are unsure where to put something."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L("Open the folder")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: model.vaultRoot))
                    }
                    Button(L("Read the read-me")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath:
                            (model.vaultRoot as NSString).appendingPathComponent(VaultGuide.readmeName)))
                    }
                    Button(L("Rebuild the structure")) { model.rebuildVaultStructure() }
                }
            }

            // La sección que ofrecía abrir la bóveda en Obsidian y convertirla en repositorio
            // git ya no está. No era un botón de más: enseñaba la salida antes que el producto.
            // Lo que se vende aquí es el cerebro, y más adelante la sincronización; un panel que
            // empieza invitando a llevarse los archivos a otra app convierte a BeLauncher en el
            // indexador de fondo de otro. Los archivos siguen siendo del usuario, en su carpeta,
            // en Markdown, y quien quiera abrirlos con otra cosa puede: eso es portabilidad. Otra
            // cosa es ponerlo en el escaparate.

            Section(L("Language")) {
                Picker(L("App language"), selection: $model.interfaceLanguage) {
                    ForEach(Language.allCases, id: \.self) { language in
                        Text(language.endonym).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                Text(L("The language of the window. Your brain does not change: it keeps saving and finding what you wrote in the language you wrote it in."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("From Claude, ChatGPT or Gemini")) {
                Text(L("BeLauncher speaks MCP: the assistant you already pay for can consult your brain without opening the launcher."))
                    .font(.caption).foregroundStyle(.secondary)

                MCPVerdictHeader(model: model)

                ForEach(MCPClient.all) { client in
                    MCPClientRow(model: model, client: client)
                }

                // Right under the buttons that produce it. This line used to be written to the
                // shared `status`, which is painted in "Llevártelo a otro sitio", four sections up.
                if let mcpStatus = model.mcpStatus {
                    Text(mcpStatus)
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(L("It gets written into that app's configuration **keeping whatever was already there**. You have to restart it afterwards for it to notice."))
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Hacerlo a mano") {
                    Text(model.mcpConfig)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                    Button(L("Copy the configuration")) { model.copyMCPConfig() }
                        .controlSize(.small)
                }
                .font(.caption)
                Text(L("Seven tools: remember, context for a task, what you were doing, what we decided, get ready, search and propose. Read and propose only: an assistant can suggest what it thinks the company believes, never decide it."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Team")) {
                HStack {
                    Button(L("Share…")) { model.exportTeamBundle() }
                    Button(L("Import…")) { model.importTeamBundle() }
                }
                Text(L("House rules, one per line, in the form “Name: value”. They travel inside every shared command, which is what makes your team's /proposal produce your proposal rather than whatever the model comes up with."))
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { model.teamStandardsText },
                    set: { model.teamStandardsText = $0 }
                ))
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 72)
                Text(L("Only the memories tagged “shared” go out, encrypted with a phrase only your team has. Believe never sees the key or the contents. What arrives, arrives as a proposal: nothing applies itself."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Permissions")) {
                Text(L("The calendar is asked for the first time you get ready for a meeting. Accessibility, the first time you place a window or paste into the previous app. Notifications, the first time a flow sets a timer. Nothing at launch."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            model.refreshBrainState()
            await installer.check()
        }
    }
}

// MARK: - Whether an assistant really receives anything

/// The line above the client list: the answer before the detail.
@MainActor
private struct MCPVerdictHeader: View {
    @Bindable var model: SettingsModel

    var body: some View {
        let verdict = BrainSetupCopy.summary(of: model.mcpReports)
        VStack(alignment: .leading, spacing: 8) {
            // Pill and button on their own line so the verdict below can use the full width. In a
            // 620-point window all four on one row squeezed the sentence to two words per line.
            HStack(spacing: 8) {
                VerdictPill(level: model.mcpChecking ? .unknown : verdict.level,
                            text: model.mcpChecking ? BrainSetupCopy.checkRunning : verdict.label)
                if model.mcpChecking { ProgressView().controlSize(.small) }
                Spacer(minLength: 8)
                Button(BrainSetupCopy.checkButton) { model.runMCPDiagnosis() }
                    .controlSize(.small)
                    .disabled(model.mcpChecking)
            }
            Text(model.mcpChecking
                 ? L("Starting BeLauncher and asking it, exactly as your assistant would…")
                 : verdict.headline)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Text(BrainSetupCopy.checkExplanation)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One client, with the five checks underneath when there is bad news.
///
/// The design decision that matters: a failure is never collapsed. When everything passes the
/// steps hide behind a disclosure, because nobody needs to read five green lines. When something
/// fails, the steps are already open, the failing one is named, and the fix sits right under it —
/// a person should not have to click to find out that their assistant is getting nothing.
@MainActor
private struct MCPClientRow: View {
    @Bindable var model: SettingsModel
    let client: MCPClient

    @State private var expanded = false

    var body: some View {
        let report = model.report(for: client)
        let verdict = BrainSetupCopy.verdict(for: report)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(client.name).font(.system(size: 12, weight: .medium))
                VerdictPill(level: verdict.level, text: verdict.label)
                Spacer(minLength: 8)
                // Only offered when there is nothing wrong. On a failing client the steps are
                // already open, so a toggle there would only offer to hide the bad news.
                if verdict.level == .working {
                    Button(expanded ? "Ocultar pasos" : "Ver pasos") { expanded.toggle() }
                        .buttonStyle(.link).font(.system(size: 11))
                }
                Button(model.mcpConnections[client.id] == true ? "Reconectar" : L("Connect")) {
                    model.connect(client)
                }
                .controlSize(.small)
            }

            if verdict.level == .broken {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verdict.headline)
                        .font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verdict.whatToDo)
                        .font(.system(size: 11.5, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.destructive.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.destructive).frame(width: 2)
                        .clipShape(RoundedRectangle(cornerRadius: 1))
                }
            }

            if let report, expanded || verdict.level == .broken {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(report.steps, id: \.step) { status in
                        StepLine(status: status)
                    }
                }
                .padding(.leading, 2)
            }
        }
        .padding(.vertical, 2)
        .animation(.easeInOut(duration: 0.18), value: expanded)
    }
}

/// One of the five checks. The mark and the colour agree with the words, so the row still reads
/// correctly for anyone who does not see the colour.
@MainActor
private struct StepLine: View {
    let status: MCPHealth.StepStatus

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 13)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.step.title)
                    .font(.system(size: 11))
                    .foregroundStyle(isSkipped ? .tertiary : .secondary)
                if let reason = status.outcome.reason {
                    Text(reason)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var isSkipped: Bool { status.outcome == .skipped }

    private var symbol: String {
        switch status.outcome {
        case .passed: "checkmark"
        case .skipped: "minus"
        case .failed: "xmark"
        }
    }

    private var tint: Color {
        switch status.outcome {
        case .passed: .green
        case .skipped: .secondary
        case .failed: Theme.destructive
        }
    }
}

/// A pill with words in it, never a bare dot.
///
/// The panel this replaces had a green circle that appeared as soon as a config file mentioned
/// BeLauncher, so the worst state the app could be in — answering every message and returning
/// nothing — looked exactly like the best one. A pill has room to say `responde vacío`, and that
/// is the difference between a status indicator and a decoration.
@MainActor
private struct VerdictPill: View {
    let level: BrainSetupCopy.Level
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
            .overlay(Capsule().strokeBorder(tint.opacity(0.35)))
            .fixedSize()
    }

    private var tint: Color {
        switch level {
        case .working: .green
        case .broken: Theme.destructive
        case .unknown: .secondary
        }
    }
}

// MARK: - Data

@MainActor
private struct DataTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section(L("Your data")) {
                LabeledContent(L("Database")) {
                    Text(model.store.path).font(.caption).textSelection(.enabled).lineLimit(2)
                }
                HStack {
                    Button(L("Export…")) { model.export(includeClipboard: false) }
                    Button(L("With clipboard…")) { model.export(includeClipboard: true) }
                    Button(L("Import…")) { model.importArchive() }
                }
                // How much room it takes, said out loud.
                //
                // A brain that quietly reached thirteen gigabytes is how a Mac ends up with no disk
                // left, and the person finds out from macOS rather than from us. If a database is
                // holding far more space than its contents need, that is a fact the person owns and
                // gets to act on.
                LabeledContent(L("Size")) {
                    HStack(spacing: 8) {
                        Text(model.databaseSize)
                        if model.isBloated {
                            Button(L("Compact")) { model.compactDatabase() }
                                .controlSize(.small)
                        }
                    }
                }
                if model.isBloated {
                    Text(L("It is taking far more room than its contents need. Compacting rewrites it and gives the space back; it needs enough free disk for one copy of the result."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(L("Diagnostics…")) { model.exportDiagnostics() }
                    Button(L("Show in Finder")) { model.revealDataFolder() }
                }
                if let status = model.status {
                    Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            Section(L("Coming from another launcher")) {
                HStack {
                    Button(L("Import from Alfred")) { model.importFromAlfred() }
                    Button(L("Import from Raycast…")) { model.importFromRaycast() }
                }
                Text(L("Brings your snippets and links across. It never overwrites: if you already have that keyword, yours wins and we tell you how many were skipped."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Desinstalar") {
                Text("""
                     Sal de BeLauncher, quita “Abrir al iniciar sesión”, borra BeLauncher.app y la \
                     carpeta ~/Library/Application Support/BeLauncher. Los secretos se borran desde \
                     Acceso a Llaveros buscando “com.believe.belauncher”. No se escribe nada en \
                     ningún otro sitio.
                     """)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Agents

/// Everything you can encargar, and what it is allowed to look at before it does.
@MainActor
private struct AgentsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section(L("Commands with “/”")) {
                Text(L("Type “/” in the launcher and the list appears. A command is not a shortcut: it looks at the context, asks for the permissions it needs, shows you what it is about to do, and leaves a receipt of what it did."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.packs) { pack in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Image(systemName: pack.symbol).foregroundStyle(Theme.accent)
                                .frame(width: 16)
                            Text("/\(pack.verb)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.cyan)
                            Text(pack.name).font(.system(size: 12))
                            Spacer()
                            if pack.author != "BeLauncher" {
                                Button {
                                    model.removePack(pack)
                                } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                            }
                        }
                        Text(pack.outcome).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !pack.reads.isEmpty {
                            Text("Mira: " + pack.reads.map(\.label).joined(separator: ", "))
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section(L("Share with the team")) {
                HStack {
                    Button(L("Export my commands")) { model.exportPacks() }
                    Button(L("Import commands…")) { model.importPacks() }
                }
                Text(L("Commands travel with the house rules inside them: the tone, the formats and who approves. Without that, sharing a command is sharing nothing but a name. If you already have one by that name, yours wins and you are told how many were skipped."))
                    .font(.caption).foregroundStyle(.secondary)
                if let status = model.status {
                    Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            Section("Lienzos") {
                ForEach(CanvasTemplate.all) { definition in
                    HStack {
                        Image(systemName: "square.grid.2x2").foregroundStyle(Theme.accent)
                            .frame(width: 16)
                        Text(definition.title).font(.system(size: 12))
                        Spacer()
                        Text("\(definition.blocks.count) bloques")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                Text(L("When a job is not one answer but several pieces, a canvas opens: every block fills itself in, you edit it, and you run whichever ones you want. It closes and it is gone: not one more document to keep."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - What it watches

/// The three things the app can watch, each with its own switch, its own explanation and its own
/// delete button. Nothing here is on when the app is installed.
@MainActor
private struct MemoryTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section(L("Working memory")) {
                Toggle(L("Remember what I have been working on"), isOn: $model.graphEnabled)
                Text(L("It keeps who, which project, which file and which meeting, and how they connect. It is what makes “what did we promise Andrés?” or “pick up what I was doing before the call” work at all. It keeps **names and dates, never the contents** of a file, a message or a page."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.graphSummary.isEmpty {
                    Text(L("Still empty.")).font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(model.graphSummary, id: \.kind) { entry in
                        HStack {
                            Image(systemName: entry.kind.symbol).foregroundStyle(Theme.accent)
                                .frame(width: 16)
                            Text(entry.kind.label).font(.system(size: 12))
                            Spacer()
                            Text("\(entry.count)").font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button(L("Delete the working memory")) { model.clearGraph() }
            }

            Section("Detectar rutinas") {
                Toggle(L("Offer me commands when I repeat something"), isOn: $model.habitsEnabledSetting)
                Text(L("It notes **what kind of thing** you do and when — opening this app, running that command — never its contents. When the same sequence repeats four times, it offers to turn it into a command. If you say no, it never asks about that one again. It deletes itself after %@ days.", String(Store.habitRetentionDays)))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.recentActions.isEmpty {
                    Text(L("Nothing noted.")).font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(model.recentActions.prefix(12)) { action in
                        HStack {
                            Text(action.label).font(.system(size: 11)).lineLimit(1)
                            Spacer()
                            Text(action.at.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    Text(L("Showing the last 12 of %@.", String(model.recentActions.count)))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Button(L("Clear the history")) { model.clearHistory() }
            }

            Section(L("How you work")) {
                Toggle("Aprender mi estilo", isOn: $model.learningEnabledSetting)
                Text(L("It learns from what you accept and from what you rewrite: whether you cut things short, whether you open with a greeting, how you name your files. Nothing changes what it produces until four observations agree. **The conclusion is kept, never the text** it came from."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.learnedTraits.isEmpty {
                    Text(L("It has not learned anything yet.")).font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(model.learnedTraits) { trait in
                        HStack(alignment: .top) {
                            Image(systemName: trait.isUsable ? "checkmark.circle.fill" : "eye")
                                .foregroundStyle(trait.isUsable ? .green : .secondary)
                                .font(.system(size: 11)).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(trait.explanation).font(.system(size: 12))
                                Text(trait.isUsable
                                     ? L("%@ times · already in use", String(trait.observations))
                                     : L("%@ times · still watching", String(trait.observations)))
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button {
                                model.forget(trait)
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button(L("Forget all of it")) { model.forgetEverythingLearned() }
                }
            }

            Section(L("Read the screen")) {
                LabeledContent("Atajo", value: "⌥⇧Espacio")
                Text(L("With anything in front of you: an error, an invoice, an email, a table. It first tries to read whatever you have **selected**, which needs no screen permission. Only if there is no selection does it take a picture, read it on your Mac with Apple's recogniser, and throw it away. **No image is ever kept or uploaded.**"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
