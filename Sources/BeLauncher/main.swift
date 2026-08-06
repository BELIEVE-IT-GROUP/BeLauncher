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


// Menu-bar only: no Dock icon, no main window (LSUIElement is also set in Info.plist).
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
