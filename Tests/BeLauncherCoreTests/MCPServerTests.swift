import Testing
import Foundation
@testable import BeLauncherCore

@Suite("The brain over MCP")
@MainActor
struct MCPServerTests {

    private func vault(with objects: [MemoryObject] = []) throws -> Vault {
        let vault = try Vault(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-\(UUID().uuidString)").path)
        try objects.forEach(vault.save)
        return vault
    }

    private func decision(_ statement: String, entities: [String] = ["pricing"]) -> MemoryObject {
        MemoryObject(level: .committed, kind: .decision, statement: statement,
                     source: "Reunión de producto", owner: "Jorge",
                     createdAt: .now.addingTimeInterval(-100),
                     validFrom: .now.addingTimeInterval(-100), entities: entities)
    }

    // MARK: - Protocol

    @Test("it answers the handshake an MCP client expects")
    func initialize() throws {
        let response = try #require(MCPServer.handle(
            ["jsonrpc": "2.0", "id": 1, "method": "initialize"], vault: try vault()
        ))
        #expect(response["jsonrpc"] as? String == "2.0")
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == MCPServer.protocolVersion)
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "belauncher-brain")
    }

    @Test("every tool is listed with a schema a model can actually fill")
    func toolsList() throws {
        let response = try #require(MCPServer.handle(
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"], vault: try vault()
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

    @Test("a notification gets no reply, as the protocol requires")
    func notificationsAreSilent() throws {
        #expect(MCPServer.handle(["jsonrpc": "2.0", "method": "notifications/initialized"],
                                 vault: try vault()) == nil)
    }

    @Test("an unknown method is refused properly, not ignored")
    func unknownMethod() throws {
        let response = try #require(MCPServer.handle(
            ["jsonrpc": "2.0", "id": 3, "method": "does/notExist"], vault: try vault()
        ))
        #expect((response["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    // MARK: - The tools themselves

    @Test("Claude asking what we decided gets the decision in force, with its source")
    func whatDidWeDecide() throws {
        let vault = try vault(with: [decision("Precio enterprise: 2000 al año")])
        let response = MCPServer.call(name: "what_did_we_decide",
                                      arguments: ["topic": "precio enterprise"], vault: vault)
        #expect(!response.isError)
        #expect(response.text.contains("2000"))
        #expect(response.text.contains("Fuentes:"), "an answer without its source is a guess")
        #expect(response.text.contains("Reunión de producto"))
    }

    @Test("an empty brain says so rather than inventing")
    func emptyBrain() throws {
        let response = MCPServer.call(name: "what_did_we_decide",
                                      arguments: ["topic": "pricing"], vault: try vault())
        #expect(response.text.contains("⚠︎"))
    }

    @Test("search reports whether each memory is still in force")
    func searchReportsValidity() throws {
        var old = decision("Precio enterprise: 1500")
        old.status = .superseded
        let vault = try vault(with: [old, decision("Precio enterprise: 2000")])

        let current = MCPServer.call(name: "search_memory",
                                     arguments: ["query": "precio enterprise"], vault: vault)
        #expect(current.text.contains("2000"))
        #expect(!current.text.contains("1500"), "a retired decision is not an answer")

        let all = MCPServer.call(name: "search_memory",
                                 arguments: ["query": "precio enterprise",
                                             "include_superseded": true], vault: vault)
        #expect(all.text.contains("1500"))
        #expect(all.text.contains("sustituida"))
    }

    @Test("an assistant can propose, and only propose")
    func proposeOnly() throws {
        let vault = try vault()
        let response = MCPServer.call(
            name: "propose_memory",
            arguments: ["statement": "El cliente pidió facturación anual", "kind": "commitment"],
            vault: vault
        )
        #expect(!response.isError)
        #expect(response.text.contains("confirmarla"))

        #expect(vault.current().isEmpty, "nothing entered the brain without a person")
        #expect(vault.commits(state: .proposed).count == 1)

        // There is no tool that could confirm it.
        #expect(!MCPServer.tools.contains { $0.name.contains("confirm") })
        #expect(!MCPServer.tools.contains { $0.name.contains("delete") })
    }

    @Test("a proposal that would contradict the brain says so up front")
    func proposalReportsConflicts() throws {
        let vault = try vault()
        _ = try vault.confirm(commitID: try vault.propose(
            decision("Precio enterprise: 1500 al año")).id)

        let response = MCPServer.call(
            name: "propose_memory",
            arguments: ["statement": "Precio enterprise: 2000 al año", "kind": "decision",
                        "entities": ["pricing"]],
            vault: vault
        )
        #expect(response.text.contains("Chocaría"))
    }

    @Test("bad arguments are refused, never guessed")
    func refusesBadArguments() throws {
        let vault = try vault()
        #expect(MCPServer.call(name: "what_did_we_decide", arguments: [:], vault: vault).isError)
        #expect(MCPServer.call(name: "propose_memory", arguments: ["statement": "  "],
                               vault: vault).isError)
        #expect(MCPServer.call(name: "no_such_tool", arguments: [:], vault: vault).isError)
    }
}
