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
        case general, intelligence, clipboard, commands, agents, memory, content, brain, data
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .intelligence: "Inteligencia"
            case .clipboard: "Portapapeles"
            case .commands: "Qué puedo escribir"
            case .agents: "Encargos"
            case .memory: "Lo que observa"
            case .content: "Mis atajos"
            case .brain: "Mi cerebro"
            case .data: "Datos y privacidad"
            }
        }

        var subtitle: String {
            switch self {
            case .general: "Atajo, arranque, licencia"
            case .intelligence: "Qué modelo responde y con qué clave"
            case .clipboard: "Qué se guarda y qué no"
            case .commands: "Todo lo que entiende la ventana"
            case .agents: "Comandos con «/» y misiones en marcha"
            case .memory: "Historial, memoria de trabajo y lo aprendido"
            case .content: "Snippets, flujos, alias, secretos"
            case .brain: "Dónde viven tus notas y quién puede leerlas"
            case .data: "Exportar, importar, desinstalar"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .intelligence: "sparkles"
            case .clipboard: "doc.on.clipboard"
            case .commands: "command"
            case .agents: "terminal"
            case .memory: "eye"
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
                case .clipboard: ClipboardTab(model: model)
                case .commands: CommandsTab()
                case .agents: AgentsTab(model: model)
                case .memory: MemoryTab(model: model)
                case .content: ContentTab(model: model)
                case .brain: BrainTab(model: model)
                case .data: DataTab(model: model)
                }
            }
            .navigationTitle(selection.title)
        }
        .frame(width: 860, height: 620)
        .onAppear { model.reload(); model.scanLocalModels(); model.reloadIntelligenceExtras() }
    }
}

// MARK: - General

@MainActor
private struct GeneralTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Atajo global", selection: $model.hotkey) {
                    ForEach(HotKey.Combo.all, id: \.label) { Text($0.label).tag($0.label) }
                }
                LabeledContent("Portapapeles", value: "⌥C")
                Toggle("Abrir BeLauncher al iniciar sesión", isOn: $model.launchAtLogin)
                if let error = model.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Actualizaciones") {
                Toggle("Buscar actualizaciones", isOn: $model.updateCheckEnabled)
                UpdateRow(model: model)
                Text("BeLauncher no tiene cuenta, ni analítica, ni servidor. Solo mira si hay "
                     + "versión nueva cuando se lo pides, y la instala él mismo: nada de arrastrar "
                     + "la app encima de la vieja.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Licencia") {
                if let license = model.license {
                    LabeledContent("Correo", value: license.email)
                    LabeledContent("Clave") {
                        Text(model.maskedKey).font(.system(.caption, design: .monospaced))
                    }
                    LabeledContent("Este equipo", value: DeviceIdentity.name)
                    Button("Desactivar en este equipo") { model.deactivateThisMac() }
                } else {
                    Text("Sin licencia activa.").font(.caption).foregroundStyle(.secondary)
                }
                if let status = model.licenseStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Versión", value: model.appVersion)
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
                Button("Buscar ahora") { model.checkForUpdates() }
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
                Text("Descargando…").font(.caption).foregroundStyle(.secondary)
                Button("Cancelar") { model.updater.cancel() }.controlSize(.small)
            }

        case .verifying:
            Label("Comprobando la firma de Apple…", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)

        case .installing:
            Label("Instalando…", systemImage: "arrow.down.app")
                .font(.caption).foregroundStyle(.secondary)

        case .readyToRelaunch(let version):
            HStack {
                Label("Listo: la \(version) se instaló.", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                Spacer()
                Button("Reiniciar ahora") { model.updater.relaunch() }
                    .buttonStyle(.borderedProminent)
            }

        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Text(reason).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                HStack {
                    Button("Reintentar") { model.installUpdate() }.controlSize(.small)
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
            Section("Qué modelo responde") {
                Picker("Preferido", selection: $model.aiProvider) {
                    ForEach(IntelligenceProvider.all) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }
                Toggle("Lo confidencial nunca sale del Mac", isOn: $model.confidentialStaysLocal)
                Text("Con esto activado, sacar tareas de una reunión o cualquier cosa marcada como "
                     + "material de empresa solo va a un modelo local. Si no hay ninguno, se niega "
                     + "en vez de enviarlo igualmente.")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button("Probar") { model.testIntelligence() }
                    if let status = model.aiStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Tus claves") {
                ForEach(IntelligenceProvider.all.filter { !$0.isPrivate }) { provider in
                    HStack {
                        Text(provider.name).frame(width: 100, alignment: .leading)
                        SecureField("clave", text: Binding(
                            get: { draftKeys[provider.id] ?? model.providerKeys[provider.id] ?? "" },
                            set: { draftKeys[provider.id] = $0 }
                        ))
                        Button("Guardar") {
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
                Text("Las claves van a tu Llavero y las peticiones salen de tu Mac directas al "
                     + "proveedor: nada pasa por Believe y le pagas a quien tú elijas. Nunca se "
                     + "incluyen en una exportación.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Modelos en tu Mac") {
                if !model.localScanned {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Buscando modelos locales…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if model.localInstallations.isEmpty {
                    Text(LocalModels.howToGetOne)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Abrir ollama.com") {
                        if let url = URL(string: "https://ollama.com") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } else {
                    ForEach(model.localInstallations) { installation in
                        VStack(alignment: .leading, spacing: 4) {
                            Label("\(installation.name) está corriendo",
                                  systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.system(size: 12))
                            Picker("Modelo", selection: Binding(
                                get: { model.selectedLocalModels[installation.providerID]
                                        ?? installation.models[0] },
                                set: { model.chooseLocalModel($0, for: installation.providerID) }
                            )) {
                                ForEach(installation.models, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    }
                    Text("Sin clave, sin coste por token y sin que nada salga de este Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Volver a buscar") { model.scanLocalModels() }
                    .controlSize(.small)
            }

            Section("Qué puedes pedirle") {
                ForEach(AIVerb.all) { verb in
                    HStack {
                        Image(systemName: verb.symbol).foregroundStyle(Theme.accent).frame(width: 16)
                        Text(verb.title).font(.system(size: 12))
                        Spacer()
                        if verb.sensitivity == .confidential {
                            Text("solo local").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Aparecen con ⌘K sobre cualquier texto del portapapeles.")
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
                Toggle("Guardar lo que copias", isOn: $model.clipboardEnabled)
                Stepper("Borrar después de \(model.retentionDays) días",
                        value: $model.retentionDays, in: 1...365)
                Stepper("Guardar como mucho \(model.maxItems)",
                        value: $model.maxItems, in: 20...5000, step: 20)
                Toggle("Pegar en la app anterior al elegir", isOn: $model.pasteAfterCopy)
                Button("Borrar el historial") {
                    model.store.clearClips()
                    model.status = "Historial borrado."
                }
            }

            Section("Apps excluidas") {
                if model.excludedApps.isEmpty {
                    Text("Ninguna. Lo que copies desde cualquier app se guarda.")
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
                    TextField("Nombre de la app", text: $newExclusion)
                    Button("Excluir") {
                        model.addExcludedApp(newExclusion)
                        newExclusion = ""
                    }
                    .controlSize(.small)
                }
                if !model.seenApps.isEmpty {
                    Text("Vistas últimamente: " + model.seenApps.prefix(6).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Text("Nunca se guardan las copias que los gestores de contraseñas marcan como "
                     + "confidenciales, ni nada con forma de credencial. Esto es para lo demás que "
                     + "prefieras dejar fuera.")
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
                Section("Escribe una intención") {
                    ForEach(MissionPlanner.outcomes.filter { matches($0.title) }) { outcome in
                        row(outcome.title, hint: outcome.triggers.first ?? "",
                            symbol: "wand.and.stars")
                    }
                }

                Section("Encárgale algo (escribe «/»)") {
                    ForEach(OutcomePack.builtIn.filter { matches($0.name) }) { pack in
                        row(pack.name, hint: "/\(pack.verb)", symbol: pack.symbol)
                    }
                }

                Section("Memoria de trabajo") {
                    row("Qué prometimos a alguien", hint: "qué prometimos a Andrés",
                        symbol: "hand.raised")
                    row("Abrir lo último de un proyecto", hint: "abre lo último de Atlas",
                        symbol: "clock.arrow.circlepath")
                    row("Retomar lo de antes de la llamada",
                        hint: "retoma lo que estaba haciendo", symbol: "arrow.uturn.backward")
                    row("Quién es alguien", hint: "quién es Acme", symbol: "person.text.rectangle")
                }

                Section("Pregúntale al cerebro") {
                    row("Qué decidimos sobre algo", hint: "qué decidimos sobre pricing",
                        symbol: "brain")
                    row("Prepárame para una reunión", hint: "prepárame para Acme",
                        symbol: "person.2")
                    row("Recordar algo", hint: "recordar que…", symbol: "text.badge.plus")
                    row("Qué se me escapa", hint: "pulse", symbol: "waveform.path.ecg")
                }

                Section("Sistema") {
                    ForEach(SystemCommand.all.filter { matches($0.title) }) { command in
                        row(command.title, hint: command.keywords.first ?? "",
                            symbol: command.symbol)
                    }
                }

                Section("Ventanas") {
                    ForEach(WindowCommand.all.filter { matches($0.title) }) { command in
                        row(command.title, hint: command.keywords.first ?? "",
                            symbol: command.symbol)
                    }
                }

                Section("Utilidades") {
                    row("Calcular", hint: "2+2 · 15% of 300", symbol: "equal.square")
                    row("Convertir", hint: "10 km to mi", symbol: "arrow.left.arrow.right")
                    row("Buscar archivos", hint: "f informe", symbol: "doc")
                    row("Buscar en Google, Claude, ChatGPT…", hint: "g · c · gpt", symbol: "link")
                    row("Traducir, resumir, corregir…", hint: "traducir · resume · corrige",
                        symbol: "sparkles")
                    row("Leer lo que hay en pantalla", hint: "⌥⇧Espacio",
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
                    Text("Ninguno todavía.").font(.caption).foregroundStyle(.secondary)
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
                TextField("Palabra clave", text: $snippetKeyword)
                TextField("Nombre", text: $snippetTitle)
                TextField("Texto", text: $snippetBody, axis: .vertical).lineLimit(2...5)
                if let error = model.snippetError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text("Fichas: {clipboard} {date} {time} {uuid} {cursor} {secret:NOMBRE}")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Añadir") {
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
                TextField("Palabra clave", text: $workflowKeyword)
                TextField("Nombre", text: $workflowTitle)
                TextField("Plantilla de URL", text: $workflowTemplate,
                          prompt: Text("https://example.com/search?q={query}"))
                if let error = model.workflowError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text("Solo http, https y mailto. BeLauncher nunca ejecuta scripts.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Añadir") {
                        if model.addWorkflow(keyword: workflowKeyword, title: workflowTitle,
                                             template: workflowTemplate) {
                            workflowKeyword = ""; workflowTitle = ""; workflowTemplate = ""
                        }
                    }
                }
            }

            Section("Alias") {
                if model.aliases.isEmpty {
                    Text("Ninguno. Puedes crear uno con ⌘K sobre cualquier app.")
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
                    TextField("Nombre", text: $secretName)
                    SecureField("Valor", text: $secretValue)
                    Button("Guardar") {
                        if model.addSecret(name: secretName, value: secretValue) {
                            secretName = ""; secretValue = ""
                        }
                    }
                }
                if let error = model.secretError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Text("Úsalos en snippets o workflows como {secret:NOMBRE}. Nunca se exportan.")
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
        ("recordar que …", "Propone guardar algo. Tú confirmas."),
        ("capturar reunion", "Con tus notas copiadas, saca decisiones y compromisos."),
        ("qué decidimos sobre …", "Lo que está vigente hoy, no todo lo que se dijo."),
        ("prepárame para …", "Reúne lo que sabes de alguien antes de verle."),
        ("pulse", "Qué se está pudriendo: contradicciones, vencidos, sin revisar."),
    ]

    var body: some View {
        Form {
            Section("Cómo se llena tu cerebro") {
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
                Text("Nada entra sin que tú lo confirmes. Un cerebro que se escribe solo es un "
                     + "cerebro en el que no puedes confiar.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Dónde vive") {
                LabeledContent("Carpeta") {
                    Text(model.vaultRoot).font(.caption).textSelection(.enabled).lineLimit(2)
                }
                Text("Siete carpetas ya creadas, cada una con una nota que dice qué va dentro, y un "
                     + "LÉEME que lo explica entero. Ábrelo si alguna vez dudas de dónde poner algo.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Abrir la carpeta") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: model.vaultRoot))
                    }
                    Button("Leer el LÉEME") {
                        NSWorkspace.shared.open(URL(fileURLWithPath:
                            (model.vaultRoot as NSString).appendingPathComponent("LÉEME.md")))
                    }
                    Button("Rehacer la estructura") { model.rebuildVaultStructure() }
                }
            }

            Section("Llevártelo a otro sitio") {
                HStack {
                    Button("Abrir en Obsidian") { model.openInObsidian() }
                    Button("Convertir en repositorio git") { model.makeVaultGitRepository() }
                }
                Text("Obsidian no necesita nada especial: esta carpeta ya es un almacén válido, y "
                     + "el botón se lo abre. El de git hace `git init` con un `.gitignore` sensato; "
                     + "el remoto y el push los decides tú, porque dónde acaba la memoria de tu "
                     + "empresa no es una decisión nuestra.")
                    .font(.caption).foregroundStyle(.secondary)
                if let status = model.status {
                    Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            Section("Desde Claude, ChatGPT o Gemini") {
                Text("BeLauncher habla MCP: el asistente que ya pagas puede consultar tu cerebro "
                     + "sin abrir el launcher.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.mcpConfig)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                Button("Copiar la configuración") { model.copyMCPConfig() }
                Text("Cuatro herramientas: qué decidimos, preparar, buscar y proponer. Solo lectura "
                     + "y propuesta: un asistente puede sugerir qué cree la empresa, nunca decidirlo.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Equipo") {
                HStack {
                    Button("Compartir…") { model.exportTeamBundle() }
                    Button("Importar…") { model.importTeamBundle() }
                }
                Text("Reglas de la casa, una por línea, con el formato «Nombre: valor». Viajan "
                     + "dentro de cada comando compartido, que es lo que hace que el /propuesta de "
                     + "tu equipo produzca vuestra propuesta y no la que se le ocurre al modelo.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { model.teamStandardsText },
                    set: { model.teamStandardsText = $0 }
                ))
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 72)
                Text("Solo salen las memorias etiquetadas como “shared”, cifradas con una frase que "
                     + "solo tiene tu equipo. Believe nunca ve la clave ni el contenido. Lo que "
                     + "llega llega como propuesta: nada se aplica solo.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Permisos") {
                Text("El calendario se pide la primera vez que preparas una reunión. Accesibilidad, "
                     + "la primera vez que colocas una ventana o pegas en la app anterior. "
                     + "Notificaciones, la primera vez que un flujo pone un temporizador. Nada al "
                     + "arrancar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Data

@MainActor
private struct DataTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Tus datos") {
                LabeledContent("Base de datos") {
                    Text(model.store.path).font(.caption).textSelection(.enabled).lineLimit(2)
                }
                HStack {
                    Button("Exportar…") { model.export(includeClipboard: false) }
                    Button("Con portapapeles…") { model.export(includeClipboard: true) }
                    Button("Importar…") { model.importArchive() }
                }
                HStack {
                    Button("Diagnóstico…") { model.exportDiagnostics() }
                    Button("Ver en Finder") { model.revealDataFolder() }
                }
                if let status = model.status {
                    Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            Section("Venir de otro launcher") {
                HStack {
                    Button("Importar de Alfred") { model.importFromAlfred() }
                    Button("Importar de Raycast…") { model.importFromRaycast() }
                }
                Text("Trae tus snippets y enlaces. Nunca sobrescribe: si ya tienes esa palabra "
                     + "clave, la tuya gana y te decimos cuántas se omitieron.")
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
            Section("Comandos con «/»") {
                Text("Escribe «/» en el lanzador y sale la lista. Un comando no es un atajo: mira "
                     + "el contexto, pide los permisos que necesite, te enseña qué va a hacer y "
                     + "deja recibo de lo que hizo.")
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

            Section("Compartir con el equipo") {
                HStack {
                    Button("Exportar mis comandos") { model.exportPacks() }
                    Button("Importar comandos…") { model.importPacks() }
                }
                Text("Los comandos viajan con las reglas de la casa dentro: el tono, los formatos y "
                     + "quién aprueba. Sin eso, compartir un comando es compartir solo un nombre. "
                     + "Si ya tienes uno con ese nombre, el tuyo gana y se te dice cuántos se "
                     + "omitieron.")
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
                Text("Cuando un encargo no es una respuesta sino varias piezas, se abre un lienzo: "
                     + "cada bloque se rellena solo, lo editas y ejecutas lo que quieras. Se cierra "
                     + "y desaparece: no es un documento más que mantener.")
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
            Section("Memoria de trabajo") {
                Toggle("Recordar en qué he estado trabajando", isOn: $model.graphEnabled)
                Text("Guarda quién, qué proyecto, qué archivo y qué reunión, y cómo se conectan. "
                     + "Es lo que hace que funcione «¿qué prometimos a Andrés?» o «retoma lo que "
                     + "estaba haciendo antes de la llamada». Guarda **nombres y fechas, nunca el "
                     + "contenido** de un archivo, un mensaje o una página.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.graphSummary.isEmpty {
                    Text("Todavía vacía.").font(.caption).foregroundStyle(.tertiary)
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
                Button("Borrar la memoria de trabajo") { model.clearGraph() }
            }

            Section("Detectar rutinas") {
                Toggle("Proponerme comandos cuando repito algo", isOn: $model.habitsEnabledSetting)
                Text("Anota **qué tipo de cosa** haces y cuándo — abrir tal app, ejecutar tal "
                     + "comando — nunca su contenido. Cuando la misma secuencia se repite cuatro "
                     + "veces, te ofrece convertirla en un comando. Si dices que no, no se vuelve a "
                     + "preguntar por esa. Se borra sola a los \(Store.habitRetentionDays) días.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.recentActions.isEmpty {
                    Text("Nada anotado.").font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(model.recentActions.prefix(12)) { action in
                        HStack {
                            Text(action.label).font(.system(size: 11)).lineLimit(1)
                            Spacer()
                            Text(action.at.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    Text("Se muestran las 12 últimas de \(model.recentActions.count).")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Button("Borrar el historial") { model.clearHistory() }
            }

            Section("Cómo trabajas") {
                Toggle("Aprender mi estilo", isOn: $model.learningEnabledSetting)
                Text("Aprende de lo que aceptas y de lo que reescribes: si acortas, si saludas, "
                     + "cómo nombras los archivos. Nada cambia lo que produce hasta que cuatro "
                     + "observaciones coinciden. **Se guarda la conclusión, nunca el texto** del que "
                     + "salió.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.learnedTraits.isEmpty {
                    Text("Todavía no ha aprendido nada.").font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(model.learnedTraits) { trait in
                        HStack(alignment: .top) {
                            Image(systemName: trait.isUsable ? "checkmark.circle.fill" : "eye")
                                .foregroundStyle(trait.isUsable ? .green : .secondary)
                                .font(.system(size: 11)).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(trait.explanation).font(.system(size: 12))
                                Text(trait.isUsable
                                     ? "\(trait.observations) veces · ya se aplica"
                                     : "\(trait.observations) veces · todavía mirando")
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button {
                                model.forget(trait)
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Olvidarlo todo") { model.forgetEverythingLearned() }
                }
            }

            Section("Leer la pantalla") {
                LabeledContent("Atajo", value: "⌥⇧Espacio")
                Text("Con cualquier cosa delante: un error, una factura, un correo, una tabla. "
                     + "Primero intenta leer lo que tengas **seleccionado**, que no necesita "
                     + "permiso de pantalla. Solo si no hay selección hace una foto, la lee en tu "
                     + "Mac con el reconocimiento de Apple y la descarta. **Ninguna imagen se "
                     + "guarda ni se sube.**")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
