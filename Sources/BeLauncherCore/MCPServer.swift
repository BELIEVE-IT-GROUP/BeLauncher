import Foundation

/// Exposes the brain over the Model Context Protocol, so Claude, ChatGPT or Gemini can consult it.
///
/// The inverse move, and the cheap one: instead of trying to put a chat model inside BeLauncher,
/// put BeLauncher's memory inside whatever model the person already pays for. Their subscription,
/// their choice of model, our context.
///
/// Read and propose only. No tool here can confirm a memory, delete one, or touch a file: an
/// assistant may suggest what the company believes, never decide it. That is the same rule the
/// window follows, and it matters more here because the caller is not a person.
public struct MCPServer: Sendable {

    public struct Tool: Sendable, Equatable {
        public let name: String
        public let description: String
        /// Built on demand: a JSON Schema is a dictionary of Any, which cannot be Sendable, and
        /// storing one would make the whole catalogue unusable across actors.
        public let makeSchema: @Sendable () -> [String: Any]

        public var schema: [String: Any] { makeSchema() }

        public static func == (lhs: Tool, rhs: Tool) -> Bool {
            lhs.name == rhs.name && lhs.description == rhs.description
        }

        public init(name: String, description: String,
                    schema: @escaping @Sendable () -> [String: Any]) {
            self.name = name
            self.description = description
            self.makeSchema = schema
        }
    }

    public static let protocolVersion = "2024-11-05"

    public static let tools: [Tool] = [
        Tool(
            name: "what_did_we_decide",
            description: "La decisión vigente de la empresa sobre un tema, con quién la tomó, "
                       + "desde cuándo, su fuente y a qué decisión sustituyó. Responde con lo que "
                       + "está en vigor hoy, no con todo lo que se dijo alguna vez.",
            schema: { ["type": "object",
                     "properties": ["topic": ["type": "string",
                                              "description": "El tema, por ejemplo: pricing enterprise"]],
                     "required": ["topic"]] }
        ),
        Tool(
            name: "prepare",
            description: "Reúne lo que se sabe sobre una persona, cliente o proyecto antes de una "
                       + "reunión: decisiones vigentes, compromisos abiertos y notas.",
            schema: { ["type": "object",
                     "properties": ["subject": ["type": "string"]],
                     "required": ["subject"]] }
        ),
        Tool(
            name: "search_memory",
            description: "Busca en la memoria de la empresa. Devuelve objetos con su estado, su "
                       + "dueño y si siguen vigentes.",
            schema: { ["type": "object",
                     "properties": ["query": ["type": "string"],
                                    "include_superseded": ["type": "boolean"]],
                     "required": ["query"]] }
        ),
        Tool(
            name: "propose_memory",
            description: "Propone guardar algo en la memoria de la empresa. Queda como propuesta "
                       + "hasta que una persona la confirme en BeLauncher; esta herramienta nunca "
                       + "escribe directamente en el cerebro.",
            schema: { ["type": "object",
                     "properties": ["statement": ["type": "string"],
                                    "kind": ["type": "string",
                                             "enum": MemoryObject.Kind.allCases.map(\.rawValue)],
                                    "source": ["type": "string"],
                                    "entities": ["type": "array", "items": ["type": "string"]]],
                     "required": ["statement"]] }
        ),
    ]

    // MARK: - Dispatch

    public struct Response: Sendable, Equatable {
        public let text: String
        public let isError: Bool

        public init(text: String, isError: Bool = false) {
            self.text = text
            self.isError = isError
        }
    }

    /// Runs a tool call against the vault. Pure enough to test without a transport.
    @MainActor
    public static func call(
        name: String, arguments: [String: Any], vault: Vault, events: [CalendarEvent] = [],
        at date: Date = .now
    ) -> Response {
        switch name {
        case "what_did_we_decide":
            guard let topic = arguments["topic"] as? String, !topic.isEmpty else {
                return Response(text: "Falta el tema.", isError: true)
            }
            let answer = BrainQuery.whatDidWeDecide(topic: topic, in: vault.objects(), at: date)
            return Response(text: render(answer))

        case "prepare":
            guard let subject = arguments["subject"] as? String, !subject.isEmpty else {
                return Response(text: "Falta el asunto.", isError: true)
            }
            let answer = BrainQuery.prepare(subject: subject, in: vault.objects(),
                                            events: events, at: date)
            return Response(text: render(answer))

        case "search_memory":
            guard let query = arguments["query"] as? String, !query.isEmpty else {
                return Response(text: "Falta la consulta.", isError: true)
            }
            let includeSuperseded = arguments["include_superseded"] as? Bool ?? false
            let found = BrainQuery.relevant(query, in: vault.objects(), kinds: nil)
                .filter { includeSuperseded || $0.isCurrent(at: date) }
                .prefix(10)
            guard !found.isEmpty else {
                return Response(text: "La memoria no tiene nada sobre “\(query)”.")
            }
            return Response(text: found.map { object in
                "- \(object.statement)\n  \(object.kind.rawValue) · "
                + "\(object.isCurrent(at: date) ? "vigente" : "sustituida")"
                + (object.owner.isEmpty ? "" : " · \(object.owner)")
                + (object.source.isEmpty ? "" : " · \(object.source)")
            }.joined(separator: "\n"))

        case "propose_memory":
            guard let statement = arguments["statement"] as? String,
                  !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Response(text: "Falta la frase.", isError: true)
            }
            let kind = MemoryObject.Kind(rawValue: arguments["kind"] as? String ?? "") ?? .note
            let object = MemoryObject(
                level: .extracted, kind: kind, statement: statement,
                source: arguments["source"] as? String ?? "Propuesto por un asistente",
                createdAt: date, validFrom: date,
                entities: arguments["entities"] as? [String] ?? []
            )
            do {
                let commit = try vault.propose(object, reason: "Vía MCP")
                let conflicts = commit.conflicts.isEmpty
                    ? ""
                    : " Chocaría con \(commit.conflicts.count) memoria(s) vigente(s)."
                return Response(text: "Propuesta registrada. Una persona debe confirmarla en "
                                    + "BeLauncher antes de que forme parte de la memoria.\(conflicts)")
            } catch {
                return Response(text: "No se pudo proponer: \(error)", isError: true)
            }

        default:
            return Response(text: "Esa herramienta no existe.", isError: true)
        }
    }

    static func render(_ answer: BrainQuery.Answer) -> String {
        var text = "## \(answer.headline)\n\n\(answer.body)"
        if let gap = answer.gap {
            text += "\n\n⚠︎ \(gap)"
        }
        if !answer.citations.isEmpty {
            text += "\n\nFuentes:\n"
            text += answer.citations.map { object in
                "- \(object.statement)"
                + (object.source.isEmpty ? "" : " (\(object.source))")
            }.joined(separator: "\n")
        }
        return text
    }

    // MARK: - JSON-RPC framing

    /// Builds the reply envelope for a request. The transport is stdio, so this is all the
    /// protocol handling there is.
    @MainActor
    public static func handle(
        _ request: [String: Any], vault: Vault, events: [CalendarEvent] = [], at date: Date = .now
    ) -> [String: Any]? {
        let id = request["id"]
        guard let method = request["method"] as? String else { return nil }

        switch method {
        case "initialize":
            return envelope(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "belauncher-brain", "version": "1.0.0"],
            ])

        case "tools/list":
            return envelope(id: id, result: [
                "tools": tools.map { tool in
                    ["name": tool.name, "description": tool.description, "inputSchema": tool.schema]
                },
            ])

        case "tools/call":
            let params = request["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let response = call(name: name, arguments: arguments, vault: vault,
                                events: events, at: date)
            return envelope(id: id, result: [
                "content": [["type": "text", "text": response.text]],
                "isError": response.isError,
            ])

        case "notifications/initialized":
            return nil   // a notification carries no id and expects no reply

        default:
            return envelope(id: id, error: ["code": -32601, "message": "Method not found"])
        }
    }

    static func envelope(id: Any?, result: [String: Any]? = nil,
                         error: [String: Any]? = nil) -> [String: Any] {
        var response: [String: Any] = ["jsonrpc": "2.0"]
        response["id"] = id ?? NSNull()
        if let result { response["result"] = result }
        if let error { response["error"] = error }
        return response
    }
}
