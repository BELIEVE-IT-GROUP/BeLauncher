import AppKit
import BeLauncherCore

// `BeLauncher --mcp` runs as a plain stdio server instead of a menu-bar app, which is what an
// MCP client launches. No window, no dock icon, no hotkey: just the brain on a pipe.
if CommandLine.arguments.contains("--mcp") {
    MainActor.assumeIsolated {
        guard let vault = try? Vault(root: Vault.defaultRoot()) else {
            FileHandle.standardError.write(Data("no se pudo abrir el vault\n".utf8))
            exit(1)
        }
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            guard let response = MCPServer.handle(request, vault: vault) else { continue }
            guard let out = try? JSONSerialization.data(withJSONObject: response) else { continue }
            FileHandle.standardOutput.write(out)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
    exit(0)
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

            out("\n6. ¿Se puede mover la del foco?")
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
