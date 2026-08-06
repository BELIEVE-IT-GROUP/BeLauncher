import Testing
import Foundation
@testable import BeLauncherCore

@Suite("El cerebro por MCP")
@MainActor
struct MCPServerTests {

    private func vault(with objects: [MemoryObject] = []) throws -> Vault {
        let vault = try Vault(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-\(UUID().uuidString)").path)
        try objects.forEach(vault.save)
        return vault
    }

    /// Sin cerebro semántico a propósito: esta suite mira el protocolo y la memoria deliberada.
    /// Lo que hace cada herramienta contra el índice se prueba en `MCPToolsTests`.
    private func context(_ objects: [MemoryObject] = []) throws -> MCPContext {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-store-\(UUID().uuidString)")
            .appendingPathComponent("s.sqlite3").path
        return MCPContext(vault: try vault(with: objects), store: try Store(path: path))
    }

    private func decision(_ statement: String, entities: [String] = ["pricing"]) -> MemoryObject {
        MemoryObject(level: .committed, kind: .decision, statement: statement,
                     source: "Reunión de producto", owner: "Jorge",
                     createdAt: .now.addingTimeInterval(-100),
                     validFrom: .now.addingTimeInterval(-100), entities: entities)
    }

    // MARK: - Protocolo

    @Test("responde al saludo que espera un cliente MCP")
    func initialize() async throws {
        let response = try #require(await MCPServer.handle(
            ["jsonrpc": "2.0", "id": 1, "method": "initialize"], context: try context()
        ))
        #expect(response["jsonrpc"] as? String == "2.0")
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == MCPServer.protocolVersion)
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "belauncher-brain")
    }

    @Test("cada herramienta se anuncia con un esquema que un modelo puede rellenar")
    func toolsList() async throws {
        let response = try #require(await MCPServer.handle(
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"], context: try context()
        ))
        let tools = try #require((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.count == MCPServer.tools.count)
        for tool in tools {
            #expect((tool["name"] as? String)?.isEmpty == false)
            #expect((tool["description"] as? String)?.isEmpty == false)
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect(schema["properties"] != nil)
        }
    }

    @Test("una notificación no se contesta, como manda el protocolo")
    func notificationsAreSilent() async throws {
        #expect(await MCPServer.handle(["jsonrpc": "2.0", "method": "notifications/initialized"],
                                       context: try context()) == nil)
    }

    @Test("un método desconocido se rechaza como es debido, no se ignora")
    func unknownMethod() async throws {
        let response = try #require(await MCPServer.handle(
            ["jsonrpc": "2.0", "id": 3, "method": "does/notExist"], context: try context()
        ))
        #expect((response["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    // MARK: - Las herramientas

    @Test("preguntar qué decidimos devuelve la decisión vigente con su fuente")
    func whatDidWeDecide() async throws {
        let response = await MCPServer.call(
            name: "what_did_we_decide", arguments: ["topic": "precio enterprise"],
            context: try context([decision("Precio enterprise: 2000 al año")]))
        #expect(!response.isError)
        #expect(response.text.contains("2000"))
        #expect(response.text.contains("Fuentes:"), "una respuesta sin fuente es una suposición")
        #expect(response.text.contains("Reunión de producto"))
    }

    @Test("un cerebro vacío lo dice en vez de inventar")
    func emptyBrain() async throws {
        let response = await MCPServer.call(name: "what_did_we_decide",
                                            arguments: ["topic": "pricing"],
                                            context: try context())
        #expect(response.text.contains("No hay ninguna decisión registrada"))
        #expect(response.text.contains("Busqué «pricing»"))
    }

    @Test("la búsqueda dice si cada memoria sigue vigente")
    func searchReportsValidity() async throws {
        var old = decision("Precio enterprise: 1500")
        old.status = .superseded
        let context = try context([old, decision("Precio enterprise: 2000")])

        let current = await MCPServer.call(name: "search_memory",
                                           arguments: ["query": "precio enterprise"],
                                           context: context)
        #expect(current.text.contains("2000"))
        #expect(!current.text.contains("1500"), "una decisión retirada no es una respuesta")

        let all = await MCPServer.call(name: "search_memory",
                                       arguments: ["query": "precio enterprise",
                                                   "include_superseded": true],
                                       context: context)
        #expect(all.text.contains("1500"))
        #expect(all.text.contains("sustituida"))
    }

    @Test("un asistente puede proponer, y solo proponer")
    func proposeOnly() async throws {
        let context = try context()
        let response = await MCPServer.call(
            name: "propose_memory",
            arguments: ["statement": "El cliente pidió facturación anual", "kind": "commitment"],
            context: context
        )
        #expect(!response.isError)
        #expect(response.text.contains("confirmarla"))

        #expect(context.vault.current().isEmpty, "nada entró en el cerebro sin una persona")
        #expect(context.vault.commits(state: .proposed).count == 1)

        // No existe ninguna herramienta que pudiera confirmarlo.
        #expect(!MCPServer.tools.contains { $0.name.contains("confirm") })
        #expect(!MCPServer.tools.contains { $0.name.contains("delete") })
    }

    @Test("una propuesta que contradice al cerebro lo avisa por delante")
    func proposalReportsConflicts() async throws {
        let context = try context()
        _ = try context.vault.confirm(commitID: try context.vault.propose(
            decision("Precio enterprise: 1500 al año")).id)

        let response = await MCPServer.call(
            name: "propose_memory",
            arguments: ["statement": "Precio enterprise: 2000 al año", "kind": "decision",
                        "entities": ["pricing"]],
            context: context
        )
        #expect(response.text.contains("Chocaría"))
    }

    @Test("los argumentos malos se rechazan, nunca se adivinan")
    func refusesBadArguments() async throws {
        let context = try context()
        #expect(await MCPServer.call(name: "what_did_we_decide", arguments: [:],
                                     context: context).isError)
        #expect(await MCPServer.call(name: "propose_memory", arguments: ["statement": "  "],
                                     context: context).isError)
        #expect(await MCPServer.call(name: "no_such_tool", arguments: [:], context: context).isError)
    }
}
