import AppKit
import AVFoundation
import AVFAudio
import BeLauncherCore

// Repairs the affected derived corpus in a standalone process. It deliberately runs before the
// AppKit application is created so a multi-gigabyte maintenance operation can never block the
// command bar. `--database` exists for release and migration harnesses; normal use always targets
// the person's actual local store.
if CommandLine.arguments.contains("--repair-corpus") {
    let output = { (line: String) in
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
    let path = CommandLine.arguments.firstIndex(of: "--database").flatMap { index in
        CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : nil
    } ?? Store.defaultPath()

    MainActor.assumeIsolated {
        do {
            let store = try Store(path: path)
            let before = store.fileSize
            let report = try store.repairCorpusAmplification()
            output("corpus-repaired=\(report.repaired)")
            output("removed-passages=\(report.removedPassages)")
            output("removed-episode-nodes=\(report.removedEpisodeNodes)")
            output("removed-episode-edges=\(report.removedEpisodeEdges)")
            output("trimmed-nodes=\(report.trimmedNodes)")
            output("trimmed-passages=\(report.trimmedPassages)")

            try? store.database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            if !CommandLine.arguments.contains("--no-compact") {
                let reclaimed = try store.compact()
                try? store.database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                // `VACUUM` can update the file after SQLite returns on APFS. Measure the final
                // artifact as well as the method's immediate estimate so the diagnostic never
                // reports zero after visibly reclaiming tens of gigabytes.
                let measured = max(reclaimed, before - store.fileSize)
                output("reclaimed-bytes=\(measured)")
            } else {
                output("reclaimed-bytes=0")
            }
            output("database-before=\(before)")
            output("database-after=\(store.fileSize)")
            exit(0)
        } catch {
            output("corpus-repair-error=\(error.localizedDescription)")
            exit(1)
        }
    }
}

// Read-only source probe. It exercises the same signed process and connector code as a capture
// pass, but never writes the corpus. A missing optional app database is reported as absent; an
// existing database that cannot be opened or finished is a failure, never a green zero.
if CommandLine.arguments.contains("--diagnose-sources") {
    let output = { (line: String) in
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
    let since = Date().addingTimeInterval(-7 * 24 * 60 * 60)
    let browser = BrowserHistory.read(since: since, excludedDomains: [], excludedApps: [])
    output("full-disk-access=\(Permissions.fullDiskAccessLikely)")
    output("browsers-count=\(browser.visits.count)")
    for problem in browser.problems { output("browsers-error=\(problem)") }

    let mail = LocalMailConnector.read(since: since)
    output("apple-mail-count=\(mail.messages.count)")
    if let problem = mail.problem { output("apple-mail-error=\(problem)") }

    let messages = LocalMessagesConnector.read(since: since)
    output("messages-count=\(messages.messages.count)")
    if let problem = messages.problem { output("messages-error=\(problem)") }

    let notes = LocalNotesConnector.read(since: since)
    output("notes-count=\(notes.notes.count)")
    if let problem = notes.problem { output("notes-error=\(problem)") }

    let sessions = Conversations.sessionsFolder()
    let sessionFiles = FileManager.default.enumerator(atPath: sessions)?
        .compactMap { $0 as? String }.filter { $0.hasSuffix(".jsonl") }.count ?? 0
    output("conversations-files=\(sessionFiles)")
    let hasError = !browser.problems.isEmpty || mail.problem != nil || messages.problem != nil
        || notes.problem != nil
    exit(hasError ? 1 : 0)
}

// `BeLauncher --mcp` runs as a plain stdio server instead of a menu-bar app, which is what an
// MCP client launches. No window, no dock icon, no hotkey: just the brain on a pipe.
if CommandLine.arguments.contains("--mcp") {
    MainActor.assumeIsolated {
        Task { @MainActor in
            guard let vault = try? Vault(root: Vault.defaultRoot()) else {
                FileHandle.standardError.write(Data("no se pudo abrir el vault\n".utf8))
                exit(1)
            }
            // The store and the brain, not just the vault. This is the whole point of the work
            // and it is the line where it would have been lost: the tools were rewritten to read
            // the index, but the process an assistant actually launches was still handing them a
            // vault and nothing else. Every tool would have answered "el índice no está
            // disponible" in production while every test passed, because the tests build their
            // own context with a brain in it.
            let store = try? Store(path: Store.defaultPath())
            var brain: BrainSearch?
            if let store {
                let search = BrainSearch(store: store)
                // MCP must become ready before probing Ollama or LM Studio. Model discovery is
                // lazy on the first semantic query; a local runner that is asleep cannot block
                // the assistant's initialize handshake or make the stdio server look dead.
                brain = search
            }
            guard let store else {
                FileHandle.standardError.write(Data("no se pudo abrir la base\n".utf8))
                exit(1)
            }
            let context = MCPContext(vault: vault, store: store, brain: brain)

            while let line = readLine(strippingNewline: true) {
                guard !line.isEmpty,
                      let data = line.data(using: .utf8),
                      let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                guard let response = await MCPServer.handle(request, context: context) else { continue }
                guard let out = try? JSONSerialization.data(withJSONObject: response) else { continue }
                FileHandle.standardOutput.write(out)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            exit(0)
        }
    }
    // The loop is inside a Task now because answering a tool call means embedding the question,
    // which is async. A synchronous `exit(0)` here would end the process before the first reply.
    RunLoop.main.run()
}


// `BeLauncher --diagnose-mcp` runs the same handshake an assistant runs, out loud.
//
// "Conectado" used to mean a line had been written into a config file. Four separate things can
// fail after that and three of them fail silently, so this walks all of them and prints what came
// back rather than a verdict nobody can check.
if CommandLine.arguments.contains("--diagnose-mcp") {
    MainActor.assumeIsolated {
        Task { @MainActor in
            let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let reports = await MCPProbe.diagnose(executablePath: path)
            FileHandle.standardOutput.write(Data((MCPHealth.render(reports) + "\n").utf8))
            exit(reports.contains { $0.isConnected } ? 0 : 1)
        }
    }
    RunLoop.main.run()
}


// `BeLauncher --diagnose-brain` builds the index for real and asks it real questions.
//
// Semantic search fails silently by nature: every query still returns something, so a broken
// index and a working one look identical from the outside. This runs the whole path — cut into
// passages, embed, store, fuse, expand through the graph — and prints what came back and why, so
// "no me encuentra nada" stops being a claim nobody can check.
//
// Optionally takes the questions to ask: `--diagnose-brain "qué decidimos sobre precios"`.
if CommandLine.arguments.contains("--diagnose-brain") {
    let out = { (line: String) in FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
    let asked = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }

    MainActor.assumeIsolated {
        Task { @MainActor in
            guard let store = try? Store(path: Store.defaultPath()),
                  let vault = try? Vault(root: Vault.defaultRoot()) else {
                out("No pude abrir la base ni el vault."); exit(1)
            }
            try? store.migrateSemanticIndex(repairOversizedTitles: false)
            let brain = BrainSearch(store: store)

            out("1. ¿Hay un modelo de embeddings?")
            let started = Date()
            let engine = await brain.detectEngine()
            out("   tardó \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            if let engine {
                out("   \(engine.name) · \(engine.model) \(engine.isLocal ? "(local)" : "(en la nube)")")
            } else {
                out("   ninguno. La búsqueda será solo por palabras.")
                out("   \(EmbeddingEngine.howToGetOne)")
            }

            out("\n2. Troceando lo que hay")
            let memories = vault.objects()
            let nodes = store.nodes(limit: 2_000)
            let clips = store.clips(limit: 500)
            let written = brain.index(memories: memories, nodes: nodes, clips: clips)
            out("   \(memories.count) memorias · \(nodes.count) nodos · \(clips.count) del portapapeles")
            out("   → \(written) pasajes")
            if written == 0 {
                out("   El cerebro está vacío. Guarda algo con «recordar» y vuelve a probar.")
                exit(0)
            }

            if engine != nil {
                out("\n3. Calculando vectores")
                let embedStarted = Date()
                do {
                    let done = try await brain.embedEverything()
                    let elapsed = Date().timeIntervalSince(embedStarted)
                    out("   \(done) pasajes en \(String(format: "%.1f", elapsed))s"
                        + (done > 0 ? " (\(Int(elapsed / Double(done) * 1000)) ms cada uno)" : ""))
                } catch {
                    out("   falló: \(error)")
                }
                let progress = brain.progress()
                out("   índice: \(progress.vectorised)/\(progress.passages) con vector")
            }

            let questions = asked.isEmpty
                ? ["qué decidimos", "en qué he estado trabajando", "qué tengo pendiente"]
                : Array(asked)
            out("\n4. Preguntando")
            for question in questions {
                let result = await brain.search(question, limit: 4)
                out("\n   «\(question)»")
                if let gap = result.gap { out("   ⚠︎ \(gap)") }
                for (index, hit) in result.hits.enumerated() {
                    let where_ = hit.route == .related ? "vía \(hit.via ?? "?")" : hit.route.rawValue
                    out("   \(index + 1). [\(hit.passage.source.kind.label) · \(where_)] \(hit.passage.title.prefix(58))")
                    out("      \(hit.passage.text.replacingOccurrences(of: "\n", with: " ").prefix(96))")
                }
                if result.hits.isEmpty { out("   sin resultados") }
            }
            out("")
            exit(0)
        }
    }
    RunLoop.main.run()
}


// `BeLauncher --diagnose-ai` walks the whole intelligence path out loud and exits.
//
// It exists because the AI failing in the field was undiagnosable: the window showed one line of
// error and the app had no way to say which step broke. This runs inside the real signed bundle —
// same Info.plist, same hardened runtime, same network stack — which is the only place the failure
// reproduces. Anyone can run it and paste the output.
if CommandLine.arguments.contains("--diagnose-ai") {
    let out = { (line: String) in FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
    MainActor.assumeIsolated {
        Task { @MainActor in
            out("BeLauncher \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")

            out("\n1. ¿Qué modelos locales hay corriendo?")
            let started = Date()
            let running = await LocalModels.installed()
            out("   tardó \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            if running.isEmpty {
                out("   ninguno. Ollama o LM Studio tienen que estar abiertos.")
            }
            for installation in running {
                out("   \(installation.name): \(installation.models.joined(separator: ", "))")
            }

            out("\n2. ¿Qué claves hay guardadas?")
            for provider in IntelligenceProvider.all where !provider.isPrivate {
                let has = (Keychain.get(provider.keychainAccount)?.isEmpty == false)
                out("   \(provider.name): \(has ? "sí" : "no")")
            }

            let runningIDs = Set(running.map(\.providerID))
            let available = IntelligenceProvider.all.filter { provider in
                provider.isPrivate
                    ? runningIDs.contains(provider.id)
                    : (Keychain.get(provider.keychainAccount)?.isEmpty == false)
            }
            out("\n3. Disponibles: \(available.map(\.id).joined(separator: ", "))")
            let store = try? Store(path: Store.defaultPath())
            let preferredID = store?.setting("ai_provider")
            let provider = preferredID.flatMap { preferred in
                available.first { $0.id == preferred }
            } ?? available.first
            guard let provider else {
                out("   nada disponible; no hay a quién preguntar.")
                exit(1)
            }
            let runningModels = running.first { $0.providerID == provider.id }?.models ?? []
            let savedModel = store?.setting("ai_model_\(provider.id)")
            let model = if runningModels.isEmpty {
                savedModel ?? provider.defaultModel
            } else if let savedModel, runningModels.contains(savedModel) {
                savedModel
            } else {
                runningModels[0]
            }
            out("   se usaría: \(provider.id) con el modelo \(model)")
            out("   endpoint: \(provider.endpoint)")

            out("\n4. Petición real, con streaming…")
            let asked = Date()
            do {
                final class FirstToken: @unchecked Sendable { var at: TimeInterval? }
                let first = FirstToken()
                let adapter = BELHTTPModelProvider(descriptor: provider)
                let answer = try await adapter.stream(
                    BELModelRequest(system: "Eres una herramienta dentro de un launcher.",
                                    prompt: "Escribe un párrafo sobre el mar.",
                                    sensitivity: .personal, maxTokens: 400),
                    model: model,
                    onFragment: { _ in
                        // The number that decides whether this feels instant or broken.
                        if first.at == nil { first.at = Date().timeIntervalSince(asked) }
                    }
                )
                out("   primera palabra en \(String(format: "%.1f", first.at ?? 0))s")
                out("   completo en \(String(format: "%.1f", Date().timeIntervalSince(asked)))s, "
                    + "\(answer.text.count) caracteres")
            } catch {
                out("   FALLÓ tras \(String(format: "%.1f", Date().timeIntervalSince(asked)))s")
                out("   \(String(describing: error))")
                exit(1)
            }
            exit(0)
        }
    }
    RunLoop.main.run()
}


// `BeLauncher --diagnose-windows` says exactly where window arranging breaks, for the app in
// front three seconds after launch, and exits.
//
// Same reason as `--diagnose-ai`: "no se puede saber el tamaño de la ventana" is one line with
// four possible causes behind it, and from outside the app there is no way to tell which.
if CommandLine.arguments.contains("--diagnose-windows") {
    let out = { (line: String) in FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
    MainActor.assumeIsolated {
        out("Pon delante la ventana que quieras probar. Mirando en 3 segundos…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            out("\n1. ¿Tiene permiso de Accesibilidad?")
            out("   \(AXIsProcessTrusted() ? "sí" : "NO — Ajustes › Privacidad › Accesibilidad")")

            guard let app = NSWorkspace.shared.frontmostApplication else {
                out("2. No hay ninguna app delante."); exit(1)
            }
            out("\n2. App delante: \(app.localizedName ?? "?") (pid \(app.processIdentifier))")

            let element = AXUIElementCreateApplication(app.processIdentifier)
            var windowValue: CFTypeRef?
            let windowStatus = AXUIElementCopyAttributeValue(
                element, kAXFocusedWindowAttribute as CFString, &windowValue)
            out("\n3. Ventana con el foco: \(windowStatus == .success ? "encontrada" : "AXError \(windowStatus.rawValue)")")
            guard windowStatus == .success, let windowValue else {
                out("   Esa app no expone su ventana a macOS."); exit(1)
            }
            let window = unsafeBitCast(windowValue, to: AXUIElement.self)

            var names: CFArray?
            AXUIElementCopyAttributeNames(window, &names)
            let attributes = (names as? [String]) ?? []
            out("   atributos: \(attributes.prefix(12).joined(separator: ", "))")

            out("\n4. Leer posición y tamaño")
            var positionValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            let ps = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
            let ss = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
            out("   posición: \(ps == .success ? "ok" : "AXError \(ps.rawValue)")")
            out("   tamaño:   \(ss == .success ? "ok" : "AXError \(ss.rawValue)")")
            if ps == .success, ss == .success, let positionValue, let sizeValue {
                var origin = CGPoint.zero
                var size = CGSize.zero
                let po = AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &origin)
                let so = AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size)
                out("   descodificado: \(po && so ? "ok" : "NO")  → \(Int(origin.x)),\(Int(origin.y)) \(Int(size.width))×\(Int(size.height))")
            }

            out("\n5. Todas sus ventanas")
            var listValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString,
                                             &listValue) == .success,
               let windows = listValue as? [AXUIElement] {
                out("   \(windows.count) ventana(s)")
                for (index, candidate) in windows.enumerated() {
                    var titleValue: CFTypeRef?
                    AXUIElementCopyAttributeValue(candidate, kAXTitleAttribute as CFString,
                                                  &titleValue)
                    var positionValue: CFTypeRef?
                    var sizeValue: CFTypeRef?
                    let readable =
                        AXUIElementCopyAttributeValue(candidate, kAXPositionAttribute as CFString,
                                                      &positionValue) == .success
                        && AXUIElementCopyAttributeValue(candidate, kAXSizeAttribute as CFString,
                                                         &sizeValue) == .success
                    var size = CGSize.zero
                    if let sizeValue {
                        AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size)
                    }
                    let title = (titleValue as? String) ?? "sin título"
                    out("   [\(index)] \(title.prefix(40)) — "
                        + (readable ? "\(Int(size.width))×\(Int(size.height))"
                                    : "no dice dónde está"))
                }
            } else {
                out("   no expone la lista de ventanas")
            }

            out("\n6. Qué guardaría un reparto de ventanas ahora mismo")
            switch WindowArranger.snapshot(named: "diagnostico") {
            case .taken(let workspace):
                out("   \(workspace.placements.count) ventana(s) en \(workspace.displays) pantalla(s)")
                for placement in workspace.placements.prefix(10) {
                    out("   · \(placement.applicationName) — "
                        + "\(Int(placement.width))×\(Int(placement.height)) "
                        + "en pantalla \(placement.display)")
                }
            case .failed(let why):
                out("   \(why)")
            }

            out("\n7. ¿Se puede mover la del foco?")
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable)
            out("   posición modificable: \(settable.boolValue ? "sí" : "NO — esa ventana no se deja mover")")
            AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable)
            out("   tamaño modificable:   \(settable.boolValue ? "sí" : "NO")")
            exit(0)
        }
    }
    RunLoop.main.run()
}


// Runs the permission path from the real .app bundle. The optional request flag is deliberately
// explicit because it can open a macOS consent prompt.
if CommandLine.arguments.contains("--diagnose-permissions") {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    application.finishLaunching()
    let outputURL: URL? = CommandLine.arguments.firstIndex(of: "--diagnostic-output").flatMap {
        CommandLine.arguments.indices.contains($0 + 1)
            ? URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) : nil
    }
    if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
    MainActor.assumeIsolated {
        Task { @MainActor in
            let output = { (line: String) in
                let data = Data((line + "\n").utf8)
                FileHandle.standardOutput.write(data)
                if let outputURL {
                    if !FileManager.default.fileExists(atPath: outputURL.path) {
                        FileManager.default.createFile(atPath: outputURL.path, contents: data)
                    } else if let handle = try? FileHandle(forWritingTo: outputURL) {
                        try? handle.seekToEnd()
                        try? handle.write(contentsOf: data)
                        try? handle.close()
                    }
                }
            }
            output("bundle=\(Bundle.main.bundleIdentifier ?? "missing")")
            output("version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "missing")")
            output("microphone-audio=\(AVAudioApplication.shared.recordPermission.rawValue)")
            output("microphone-capture=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
            output("microphone-before=\(Permissions.microphoneStatus.rawValue)")
            var microphoneSucceeded = Permissions.microphoneGranted
            if CommandLine.arguments.contains("--request-microphone") {
                microphoneSucceeded = await Permissions.requestMicrophone()
                output("microphone-request-granted=\(microphoneSucceeded)")
                output("microphone-after=\(Permissions.microphoneStatus.rawValue)")
            }
            var recordingSucceeded = true
            if CommandLine.arguments.contains("--record-test") {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("belauncher-microphone-test-\(UUID().uuidString).m4a")
                defer { try? FileManager.default.removeItem(at: url) }
                do {
                    guard microphoneSucceeded, Permissions.microphoneGranted else {
                        recordingSucceeded = false
                        output("microphone-recording=skipped:not-authorized")
                        throw CancellationError()
                    }
                    let recorder = try AVAudioRecorder(url: url, settings: [
                        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                        AVSampleRateKey: 44_100,
                        AVNumberOfChannelsKey: 1,
                    ])
                    let prepared = recorder.prepareToRecord()
                    let started = recorder.record()
                    try await Task.sleep(for: .milliseconds(750))
                    recorder.stop()
                    let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size])
                        as? NSNumber)?.intValue ?? 0
                    let duration = try await AVURLAsset(url: url).load(.duration).seconds
                    recordingSucceeded = prepared && started && bytes > 1_024 && duration >= 0.5
                    output("microphone-recording=prepared:\(prepared),started:\(started),bytes:\(bytes),duration:\(String(format: "%.2f", duration)),valid:\(recordingSucceeded)")
                } catch is CancellationError {
                    // The explicit not-authorized line above is the useful diagnosis.
                } catch {
                    recordingSucceeded = false
                    output("microphone-recording-error=\(error.localizedDescription)")
                }
            }
            output("full-disk-access=\(Permissions.fullDiskAccessLikely)")
            exit(microphoneSucceeded && recordingSucceeded ? 0 : 1)
        }
    }
    RunLoop.main.run()
}


// Executes the same installer as Settings from the packaged app and exits only after the final
// artifact inspection. This is a release harness, not a second installation path.
if CommandLine.arguments.contains("--diagnose-qwen-install") {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    application.finishLaunching()
    MainActor.assumeIsolated {
        Task { @MainActor in
            let output = { (line: String) in
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            }
            let installer = QwenASRInstaller.shared
            installer.selectedModel = QwenASRInstaller.smallModel
            installer.refresh()
            output("qwen-before=\(String(describing: installer.phase))")
            installer.install()
            var previousStep = ""
            while installer.isInstalling {
                let step = installer.installProgress?.step ?? ""
                if step != previousStep {
                    output("qwen-step=\(step)")
                    previousStep = step
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            installer.refresh()
            output("qwen-after=\(String(describing: installer.phase))")
            exit(installer.isReady ? 0 : 1)
        }
    }
    RunLoop.main.run()
}


if let argument = CommandLine.arguments.firstIndex(of: "--diagnose-qwen-transcribe"),
   CommandLine.arguments.indices.contains(argument + 1) {
    let audio = URL(fileURLWithPath: CommandLine.arguments[argument + 1])
    MainActor.assumeIsolated {
        Task { @MainActor in
            do {
                guard let model = QwenASRRuntime.readyModel else {
                    FileHandle.standardError.write(Data("qwen-not-ready\n".utf8))
                    exit(1)
                }
                let started = Date()
                let text = try await QwenASRRuntime.transcribe(fileAt: audio, model: model)
                FileHandle.standardOutput.write(Data(
                    "qwen-model=\(model)\nqwen-seconds=\(Date().timeIntervalSince(started))\nqwen-text=\(text)\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("qwen-error=\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }
    RunLoop.main.run()
}


// Menu-bar only: no Dock icon, no main window (LSUIElement is also set in Info.plist).
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
