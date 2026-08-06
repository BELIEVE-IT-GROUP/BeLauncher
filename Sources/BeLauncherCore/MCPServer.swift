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
///
/// This file is the catalogue and the envelope, nothing else. What each tool does lives in
/// `MCPTools`, because the two things break for different reasons: the protocol broke never, and
/// the tools broke by reading a single source. Keeping them apart means fixing one does not risk
/// the other.
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

    /// Shared by every tool that takes one. Written once because a caller that learns the argument
    /// on one tool should not have to relearn it on the next. A function rather than a constant
    /// for the same reason `Tool.makeSchema` is a closure: a schema is a dictionary of Any and
    /// cannot be a Sendable global.
    static func limitProperty() -> [String: Any] {
        ["type": "integer",
         "description": "Cuántos pasajes devolver. Entre 1 y \(MCPTools.maximumLimit), "
                      + "por defecto \(MCPTools.defaultLimit)."]
    }

    public static let tools: [Tool] = [
        Tool(
            name: "recall",
            description: "Busca por significado en todo lo que esta persona tiene indexado: "
                       + "memorias, portapapeles, grafo de trabajo y notas. Devuelve pasajes "
                       + "citados, cada uno con su origen, su fecha y por qué vía apareció. "
                       + "Úsala cuando necesites saber si el cerebro sabe algo de un tema.",
            schema: { ["type": "object",
                     "properties": ["query": ["type": "string",
                                              "description": "La pregunta, en lenguaje natural"],
                                    "limit": limitProperty()],
                     "required": ["query"]] }
        ),
        Tool(
            name: "context_for",
            description: "Reúne el material que hace falta para trabajar sobre una tarea "
                       + "concreta (rehacer un documento, escribir una propuesta, contestar a un "
                       + "cliente) y lo devuelve agrupado por origen, con la cita textual "
                       + "separada del metadato. Pídelo antes de escribir, en vez de esperar a "
                       + "que la persona te pegue el contexto a mano.",
            schema: { ["type": "object",
                     "properties": ["task": ["type": "string",
                                             "description": "La tarea, descrita como se la "
                                                          + "dirías a un compañero"],
                                    "limit": limitProperty()],
                     "required": ["task"]] }
        ),
        Tool(
            name: "what_was_i_doing",
            description: "Lo último en lo que esta persona estuvo trabajando, por tramos de "
                       + "tiempo, a partir del grafo de trabajo y del portapapeles reciente. "
                       + "Es actividad capturada, no decisiones.",
            schema: { ["type": "object",
                     "properties": ["since": ["type": "string",
                                              "description": "Desde cuándo: una duración como "
                                                           + "«24h», «7d», «2w», o «hoy», «ayer», "
                                                           + "o una fecha 2026-08-01. "
                                                           + "Por defecto, 24h."]],
                     "required": []] }
        ),
        Tool(
            name: "what_did_we_decide",
            description: "La decisión vigente de la empresa sobre un tema, con quién la tomó, "
                       + "desde cuándo, su fuente y a qué decisión sustituyó. Responde con lo que "
                       + "está en vigor hoy, no con todo lo que se dijo alguna vez, y añade el "
                       + "material indexado que la rodea.",
            schema: { ["type": "object",
                     "properties": ["topic": ["type": "string",
                                              "description": "El tema, por ejemplo: pricing enterprise"]],
                     "required": ["topic"]] }
        ),
        Tool(
            name: "prepare",
            description: "Reúne lo que se sabe sobre una persona, cliente o proyecto antes de una "
                       + "reunión: decisiones vigentes, compromisos abiertos, notas y lo que haya "
                       + "indexado sobre ello.",
            schema: { ["type": "object",
                     "properties": ["subject": ["type": "string"]],
                     "required": ["subject"]] }
        ),
        Tool(
            name: "search_memory",
            description: "Busca solo en la memoria deliberada, la que una persona confirmó. "
                       + "Devuelve objetos con su estado, su dueño y si siguen vigentes. Es la "
                       + "única que sabe responder «¿esto sigue en vigor?»; para buscar en todo "
                       + "lo demás, usa recall.",
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

    /// Runs a tool call against the whole brain. Pure enough to test without a transport.
    ///
    /// Asynchronous because retrieving by meaning has to turn the question into a vector first,
    /// and that is a round trip to the embedding model. Making the call synchronous would mean
    /// either blocking the main actor on the network or quietly dropping back to word search,
    /// which is the exact dishonesty these tools exist to avoid.
    @MainActor
    public static func call(
        name: String, arguments: [String: Any], context: MCPContext, date: Date = .now
    ) async -> Response {
        switch name {
        case "recall":
            guard let query = text(arguments["query"]) else {
                return Response(text: "Falta la consulta.", isError: true)
            }
            return await MCPTools.recall(query: query, limit: integer(arguments["limit"]),
                                         context: context)

        case "context_for":
            guard let task = text(arguments["task"]) else {
                return Response(text: "Falta la tarea.", isError: true)
            }
            return await MCPTools.contextFor(task: task, limit: integer(arguments["limit"]),
                                             context: context)

        case "what_was_i_doing":
            return MCPTools.whatWasIDoing(since: arguments["since"] as? String,
                                          context: context, date: date)

        case "what_did_we_decide":
            guard let topic = text(arguments["topic"]) else {
                return Response(text: "Falta el tema.", isError: true)
            }
            return await MCPTools.whatDidWeDecide(topic: topic, context: context, date: date)

        case "prepare":
            guard let subject = text(arguments["subject"]) else {
                return Response(text: "Falta el asunto.", isError: true)
            }
            return await MCPTools.prepare(subject: subject, context: context, date: date)

        case "search_memory":
            guard let query = text(arguments["query"]) else {
                return Response(text: "Falta la consulta.", isError: true)
            }
            return MCPTools.searchMemory(
                query: query, includeSuperseded: arguments["include_superseded"] as? Bool ?? false,
                context: context, date: date)

        case "propose_memory":
            return MCPTools.proposeMemory(arguments: arguments, context: context, date: date)

        default:
            return Response(text: "La herramienta «\(name)» no existe. Disponibles: "
                                + tools.map(\.name).joined(separator: ", ") + ".",
                            isError: true)
        }
    }

    static func text(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// JSON has one number type and clients disagree about which Swift type it lands as, so both
    /// are accepted rather than silently ignoring a limit the caller did send.
    static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let raw = value as? String { return Int(raw) }
        return nil
    }

    // MARK: - JSON-RPC framing

    /// Builds the reply envelope for a request. The transport is stdio, so this is all the
    /// protocol handling there is.
    @MainActor
    public static func handle(
        _ request: [String: Any], context: MCPContext
    ) async -> [String: Any]? {
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
            let response = await call(name: name, arguments: arguments, context: context)
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
