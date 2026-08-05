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


// Menu-bar only: no Dock icon, no main window (LSUIElement is also set in Info.plist).
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
