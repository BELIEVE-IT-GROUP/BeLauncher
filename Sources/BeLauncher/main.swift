import AppKit
import BeLauncherCore

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
                try? store.migrateSemanticIndex()
                let search = BrainSearch(store: store)
                // Without this the server starts with no engine and every answer carries the
                // "solo por palabras" warning. Correct, but needlessly worse.
                await search.detectEngine()
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
            try? store.migrateSemanticIndex()
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
            guard let provider = available.first else {
                out("   nada disponible; no hay a quién preguntar.")
                exit(1)
            }
            let model = running.first { $0.providerID == provider.id }?.models.first
            out("   se usaría: \(provider.id) con el modelo \(model ?? provider.defaultModel)")
            out("   endpoint: \(provider.endpoint)")

            out("\n4. Petición real, con streaming…")
            let asked = Date()
            do {
                final class FirstToken: @unchecked Sendable { var at: TimeInterval? }
                let first = FirstToken()
                let answer = try await IntelligenceClient().stream(
                    IntelligenceRequest(system: "Eres una herramienta dentro de un launcher.",
                                        prompt: "Escribe un párrafo sobre el mar.",
                                        sensitivity: .personal, maxTokens: 400),
                    using: provider, model: model,
                    onFragment: { _ in
                        // The number that decides whether this feels instant or broken.
                        if first.at == nil { first.at = Date().timeIntervalSince(asked) }
                    }
                )
                out("   primera palabra en \(String(format: "%.1f", first.at ?? 0))s")
                out("   completo en \(String(format: "%.1f", Date().timeIntervalSince(asked)))s, "
                    + "\(answer.count) caracteres")
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


// Menu-bar only: no Dock icon, no main window (LSUIElement is also set in Info.plist).
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
