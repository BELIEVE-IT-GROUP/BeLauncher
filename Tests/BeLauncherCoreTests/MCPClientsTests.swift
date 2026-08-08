import Testing
import Foundation
@testable import BeLauncherCore

/// Writing into someone else's configuration file. The rule is: never take away what was there.
@Suite("Conectar el asistente que ya usas")
struct MCPSetupTests {

    static let client = MCPClient(id: "x", name: "Claude Desktop", configPath: "c.json")

    @Test("se añade a un archivo vacío")
    func addsToEmpty() throws {
        let (data, wasAlready) = try MCPSetup.merge(into: nil, client: Self.client,
                                                    executablePath: "/A.app/x")
        #expect(!wasAlready)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        let entry = try #require(servers["belauncher"] as? [String: Any])
        #expect(entry["command"] as? String == "/A.app/x")
        #expect(entry["args"] as? [String] == ["--mcp"])
    }

    @Test("no se lleva por delante las conexiones que ya tenía")
    func keepsWhatWasThere() throws {
        let existing = Data(#"{"mcpServers":{"otro":{"command":"/bin/otro"}},"algoMio":true}"#.utf8)
        let (data, _) = try MCPSetup.merge(into: existing, client: Self.client,
                                            executablePath: "/A.app/x")
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])

        #expect(servers["otro"] != nil, "borrar los servidores de alguien es imperdonable")
        #expect(servers["belauncher"] != nil)
        #expect(root["algoMio"] as? Bool == true, "y tampoco el resto del archivo")
    }

    @Test("conectar dos veces lo dice en vez de duplicar")
    func idempotent() throws {
        let first = try MCPSetup.merge(into: nil, client: Self.client, executablePath: "/A")
        let second = try MCPSetup.merge(into: first.data, client: Self.client,
                                        executablePath: "/B")
        #expect(second.wasAlready)

        let root = try #require(JSONSerialization.jsonObject(with: second.data) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(servers.count == 1)
        let entry = try #require(servers["belauncher"] as? [String: Any])
        #expect(entry["command"] as? String == "/B", "reconectar actualiza la ruta")
    }

    @Test("un archivo roto se deja en paz en vez de sobrescribirlo")
    func refusesToClobberBrokenJSON() {
        // Ahí puede haber otras conexiones suyas: mejor decirlo que perderlas.
        #expect(throws: MCPSetupError.unreadable("Claude Desktop")) {
            try MCPSetup.merge(into: Data("{ esto no es json".utf8), client: Self.client,
                               executablePath: "/A")
        }
    }

    @Test("VS Code usa otra clave, y se respeta")
    func honoursTheClientsOwnShape() throws {
        let vscode = try #require(MCPClient.all.first { $0.id == "vscode" })
        #expect(vscode.serversKey == "servers")

        let (data, _) = try MCPSetup.merge(into: nil, client: vscode, executablePath: "/A")
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["servers"] != nil)
        #expect(root["mcpServers"] == nil, "escribir la clave equivocada no conecta nada")
    }

    @Test("se sabe si ya está conectado sin tocar nada")
    func readsStateWithoutWriting() throws {
        #expect(!MCPSetup.isConnected(nil, client: Self.client))
        #expect(!MCPSetup.isConnected(Data("{}".utf8), client: Self.client))
        #expect(!MCPSetup.isConnected(Data("roto".utf8), client: Self.client))

        let (data, _) = try MCPSetup.merge(into: nil, client: Self.client, executablePath: "/A")
        #expect(MCPSetup.isConnected(data, client: Self.client))
    }

    @Test("una conexión vieja no se presenta como actual")
    func stalePathIsNotCurrent() throws {
        let (data, _) = try MCPSetup.merge(into: nil, client: Self.client,
                                            executablePath: "/old/BeLauncher")
        #expect(MCPSetup.executablePath(in: data, client: Self.client) == "/old/BeLauncher")
        #expect(!MCPSetup.isCurrent(data, client: Self.client,
                                    executablePath: "/Applications/BeLauncher.app/Contents/MacOS/BeLauncher"))
        #expect(MCPSetup.isCurrent(data, client: Self.client,
                                   executablePath: "/old/BeLauncher"))
    }

    @Test("cada cliente conocido tiene una ruta bajo la carpeta personal")
    func pathsAreSane() {
        for client in MCPClient.all {
            #expect(!client.configPath.hasPrefix("/"), "\(client.name) debe ser relativa a ~")
            #expect(client.configPath.hasSuffix(".json"))
            #expect(client.absoluteConfigPath(home: "/Users/x").hasPrefix("/Users/x/"))
        }
    }
}

@Suite("Guardar dónde está cada ventana")
struct WorkspaceTests {

    static func placement(_ app: String, x: Double = 0, width: Double = 800,
                          display: Int = 0) -> Workspace.Placement {
        Workspace.Placement(bundleIdentifier: "com.\(app)", applicationName: app,
                            windowTitle: "\(app) 1", x: x, y: 0, width: width, height: 600,
                            display: display)
    }

    @Test("se avisa ANTES de mover, si faltan apps")
    func warnsAboutMissingApps() throws {
        let workspace = Workspace(name: "trabajo",
                                  placements: [Self.placement("Notion"), Self.placement("Terminal")],
                                  displays: 1)
        let fit = WorkspaceLayouts.fit(workspace, displays: 1, runningBundles: ["com.Notion"])
        guard case .missingApps(let names) = fit else {
            Issue.record("no avisó: \(fit)"); return
        }
        #expect(names == ["Terminal"])
        #expect(try #require(fit.warning).contains("Terminal"))
    }

    @Test("se avisa si hay menos pantallas que cuando se guardó")
    func warnsAboutFewerDisplays() throws {
        let workspace = Workspace(name: "escritorio", placements: [Self.placement("Notion")],
                                  displays: 2)
        let fit = WorkspaceLayouts.fit(workspace, displays: 1, runningBundles: ["com.Notion"])
        // Quien desconecta el portátil debe saberlo, no buscar una ventana en una pantalla que no está.
        #expect(try #require(fit.warning).contains("2 displays"))
    }

    @Test("con todo en su sitio no se avisa de nada")
    func silentWhenItFits() {
        let workspace = Workspace(name: "x", placements: [Self.placement("Notion")], displays: 1)
        #expect(WorkspaceLayouts.fit(workspace, displays: 1,
                                     runningBundles: ["com.Notion"]) == .exact)
    }

    @Test("las tiras y paletas no se guardan como si fueran el reparto")
    func ignoresPanels() {
        // Chrome reporta ventanas de 41 píxeles de alto; un reparto lleno de eso restaura un lío.
        #expect(!WorkspaceLayouts.isWorthSaving(width: 3840, height: 41))
        #expect(!WorkspaceLayouts.isWorthSaving(width: 120, height: 800))
        #expect(WorkspaceLayouts.isWorthSaving(width: 800, height: 600))
    }

    @Test("una ventana que iba a una pantalla que ya no existe se trae a la que hay")
    func clampsHome() {
        let far = Self.placement("Notion", x: 5_000, width: 1_600, display: 1)
        let screen = WindowLayoutMath.Frame(x: 0, y: 0, width: 1_440, height: 900)
        let brought = WorkspaceLayouts.clamp(far, into: screen)

        #expect(brought.x >= 0)
        #expect(brought.x + brought.width <= 1_440)
        #expect(brought.width <= 1_440, "no cabe entera: se encoge en vez de salirse")
        #expect(brought.display == 0)
    }

    @Test("se escribe como se dice")
    func recognisesTyping() {
        #expect(WorkspaceLayouts.Intent.detect("guardar espacio trabajo") == .save("trabajo"))
        #expect(WorkspaceLayouts.Intent.detect("espacio trabajo") == .restore("trabajo"))
        #expect(WorkspaceLayouts.Intent.detect("espacios") == .list)
        #expect(WorkspaceLayouts.Intent.detect("guardar espacio ") == nil, "sin nombre no hay espacio")
        #expect(WorkspaceLayouts.Intent.detect("espacio") == nil)
        #expect(WorkspaceLayouts.Intent.detect("notion") == nil)
    }

    @Test("el resumen dice qué apps hay dentro, no cuántas ventanas")
    func summaryNamesApps() {
        let workspace = Workspace(
            name: "x",
            placements: [Self.placement("Notion"), Self.placement("Notion"), Self.placement("Terminal")],
            displays: 1
        )
        #expect(workspace.summary.contains("Notion"))
        #expect(workspace.summary.contains("Terminal"))
    }
}

extension WorkspaceTests {

    @Test("el escritorio no es una ventana del reparto")
    func ignoresTheDesktop() {
        // El Finder reporta una «ventana» que abarca las tres pantallas: 10720 de ancho.
        #expect(WorkspaceLayouts.spansEverything(width: 10_720, widestScreen: 3_840))
        #expect(!WorkspaceLayouts.spansEverything(width: 3_067, widestScreen: 3_840))
        // Una ventana maximizada en la pantalla más ancha sigue siendo una ventana.
        #expect(!WorkspaceLayouts.spansEverything(width: 3_840, widestScreen: 3_840))
    }
}
