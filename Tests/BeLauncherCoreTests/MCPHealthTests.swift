import Testing
import Foundation
@testable import BeLauncherCore

/// "Conectado" tiene que significar que el circuito entero funciona, no que un archivo de
/// configuración menciona a BeLauncher. Estas pruebas cubren los cinco pasos reales y el caso que
/// motivó todo esto: todo responde, pero la última llamada viene vacía.
///
/// La mitad de este archivo era circular y por eso no cazó nada. Las pruebas del paso final
/// alimentaban frases que ninguna herramienta escribe nunca ("La memoria no tiene nada sobre
/// eso."): eran la lista de marcadores devuelta a sí misma, así que pasaban en verde mientras el
/// texto de verdad ("La memoria deliberada no tiene ningún objeto sobre «…»") no coincidía con
/// ningún marcador y daba por buena una conexión que no devolvía nada. Ahora el texto lo produce
/// `MCPServer` de verdad, contra un vault y un índice de verdad: si alguien reescribe un mensaje
/// de `MCPTools`, estas pruebas siguen siendo válidas, porque no dependen de cómo esté redactado.
@Suite("Que conectado signifique algo")
struct MCPHealthTests {

    /// El eco de esta ejecución. Ya no hay valor por defecto: una constante pública y fija
    /// dejaba pasar cualquier respuesta que repitiera la pregunta, que es justo lo que hace
    /// toda herramienta en su «no encontré nada».
    static let eco = "ecoDePrueba7f3a"


    // MARK: - Helpers para armar respuestas JSON-RPC de mentira

    static func initializeReply(protocolVersion: String? = "2024-11-05") -> String {
        var result: [String: Any] = ["capabilities": [:] as [String: Any]]
        if let protocolVersion { result["protocolVersion"] = protocolVersion }
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": 1, "result": result]
        return json(envelope)
    }

    static func toolsListReply(names: [String]) -> String {
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": 2, "result": [
            "tools": names.map { ["name": $0, "description": "x", "inputSchema": [:] as [String: Any]] },
        ]]
        return json(envelope)
    }

    static func toolCallReply(text: String, isError: Bool = false) -> String {
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": 3, "result": [
            "content": [["type": "text", "text": text]],
            "isError": isError,
        ]]
        return json(envelope)
    }

    static func rpcError(_ message: String) -> String {
        json(["jsonrpc": "2.0", "id": 1, "error": ["code": -32000, "message": message]])
    }

    static func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    // MARK: - Andamiaje contra el cerebro de verdad

    @MainActor
    private func store() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-salud-\(UUID().uuidString)")
            .appendingPathComponent("s.sqlite3").path
        let made = try Store(path: path)
        try made.migrateSemanticIndex()
        return made
    }

    @MainActor
    private func vault(_ objects: [MemoryObject] = []) throws -> Vault {
        let made = try Vault(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-salud-vault-\(UUID().uuidString)").path)
        try objects.forEach(made.save)
        return made
    }

    /// Planta el canario igual que la sonda: una sola fuente en el índice de pasajes, sin tocar
    /// el vault de la persona y sin reindexar nada.
    @MainActor
    private func plant(_ canary: MCPHealth.Canary, in store: Store) {
        store.replacePassages(for: IndexedSource(kind: .note, id: "belauncher-sonda-mcp"),
                              title: MCPHealth.Canary.mark, occurredAt: .now,
                              text: canary.statement)
    }

    /// El sobre JSON-RPC exacto que le llega al asistente, producido por el servidor de verdad.
    @MainActor
    private func reply(tool: String, arguments: [String: Any],
                       context: MCPContext) async throws -> String {
        let response = await MCPServer.handle(
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": ["name": tool, "arguments": arguments]],
            context: context)
        let envelope = try #require(response)
        return Self.json(envelope)
    }

    // MARK: - El caso que importa: todo responde y el cerebro no devuelve nada

    @Test("la respuesta real de search_memory sin nada NO cuenta como conectado")
    @MainActor
    func searchMemoryVacioNoConecta() async throws {
        let canary = MCPHealth.Canary.make()
        let context = MCPContext(vault: try vault(), store: try store())
        let raw = try await reply(tool: "search_memory",
                                  arguments: ["query": canary.needle], context: context)

        let outcome = MCPHealth.evaluateToolCall(raw, echoing: canary.echo)
        guard case .failed(let reason) = outcome else {
            Issue.record("debía fallar, dio \(outcome)"); return
        }
        #expect(reason.contains("sin dato real"))
    }

    @Test("la respuesta real de recall sin nada NO cuenta como conectado")
    @MainActor
    func recallVacioNoConecta() async throws {
        let canary = MCPHealth.Canary.make()
        let made = try store()
        let context = MCPContext(vault: try vault(), store: made, brain: BrainSearch(store: made))
        let raw = try await reply(tool: "recall",
                                  arguments: ["query": canary.needle], context: context)

        #expect(!MCPHealth.evaluateToolCall(raw, echoing: canary.echo).isHealthy)
    }

    @Test("recall sin cerebro cableado NO cuenta como conectado")
    @MainActor
    func recallSinCerebroNoConecta() async throws {
        // El escenario del panel en verde con el cerebro desenchufado: el proceso arranca, saluda,
        // anuncia herramientas y contesta, pero `context.brain` es nil y el asistente recibe humo.
        let canary = MCPHealth.Canary.make()
        let context = MCPContext(vault: try vault(), store: try store(), brain: nil)
        let raw = try await reply(tool: "recall",
                                  arguments: ["query": canary.needle], context: context)

        #expect(!MCPHealth.evaluateToolCall(raw, echoing: canary.echo).isHealthy)
    }

    @Test("el canario plantado vuelve por recall y eso sí cuenta como conectado")
    @MainActor
    func canarioVuelvePorRecall() async throws {
        let canary = MCPHealth.Canary.make()
        let made = try store()
        plant(canary, in: made)
        let context = MCPContext(vault: try vault(), store: made, brain: BrainSearch(store: made))
        let raw = try await reply(tool: "recall",
                                  arguments: ["query": canary.needle, "limit": 20],
                                  context: context)

        #expect(MCPHealth.evaluateToolCall(raw, echoing: canary.echo).isHealthy)
    }

    @Test("devolver la pregunta no basta: la sonda busca lo que nunca preguntó")
    @MainActor
    func devolverLaPreguntaNoBasta() async throws {
        // La trampa del arreglo ingenuo. Toda herramienta repite la consulta dentro de su «no
        // encontré nada», así que comprobar que la respuesta contiene lo que se preguntó daría
        // verde con el cerebro vacío. Por eso se pregunta por `needle` y se espera `echo`.
        let canary = MCPHealth.Canary.make()
        let context = MCPContext(vault: try vault(), store: try store())
        let raw = try await reply(tool: "search_memory",
                                  arguments: ["query": canary.needle], context: context)

        #expect(raw.contains(canary.needle), "la herramienta sí repite la pregunta")
        #expect(!MCPHealth.evaluateToolCall(raw, echoing: canary.echo).isHealthy)
    }

    @Test("un dato correcto que dice «falta la» ya no se reporta en rojo")
    @MainActor
    func datoCorrectoConFaltaLaNoEsRojo() async throws {
        // «falta la» era uno de los marcadores de respuesta vacía, así que esta respuesta, que
        // trae un dato real y útil, se reportaba como circuito roto.
        let canary = MCPHealth.Canary.make()
        let made = try store()
        plant(canary, in: made)
        made.replacePassages(for: IndexedSource(kind: .note, id: "acme"), title: "Acme",
                             occurredAt: .now,
                             text: "A Acme le falta la firma del contrato y por eso el "
                                 + "\(canary.needle) sigue pendiente de cierre este trimestre.")
        let context = MCPContext(vault: try vault(), store: made, brain: BrainSearch(store: made))
        let raw = try await reply(tool: "recall",
                                  arguments: ["query": canary.needle, "limit": 20],
                                  context: context)

        #expect(raw.contains("falta la"))
        #expect(MCPHealth.evaluateToolCall(raw, echoing: canary.echo).isHealthy)
    }

    @Test("sin canario plantado la última llamada no se da por buena")
    func sinCanarioNoSeCertifica() {
        let outcome = MCPHealth.evaluateToolCall(
            Self.toolCallReply(text: "- Believe cerró la ronda semilla en marzo."), echoing: "")
        guard case .failed(let reason) = outcome else {
            Issue.record("debía fallar, dio \(outcome)"); return
        }
        #expect(reason.contains("índice"))
    }

    @Test("una llamada que devuelve texto vacío NO cuenta como conectado")
    func textoVacioNoConecta() {
        let report = MCPHealth.report(
            clientName: "Claude Desktop", configured: true, launch: .started,
            handshake: Self.initializeReply(), toolsList: Self.toolsListReply(names: ["recall"]),
            toolCall: Self.toolCallReply(text: ""), echoing: Self.eco
        )
        #expect(!report.isConnected)
        #expect(report.firstFailure?.step == .toolCalled)
    }

    @Test("un handshake correcto con tools/list vacío NO cuenta como conectado")
    func toolsListVacioNoConecta() {
        let report = MCPHealth.report(
            clientName: "Claude Desktop", configured: true, launch: .started,
            handshake: Self.initializeReply(), toolsList: Self.toolsListReply(names: []),
            toolCall: nil, echoing: Self.eco
        )
        #expect(!report.isConnected)
        #expect(report.firstFailure?.step == .toolsListed)
    }

    // MARK: - El comando que el cliente tiene guardado, no el nuestro

    @Test("se lee el comando que el cliente arrancaría, con sus argumentos")
    func comandoGuardado() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "mcpServers": ["belauncher": ["command": "/Users/x/Downloads/BeLauncher.app/Contents/MacOS/BeLauncher",
                                          "args": ["--mcp"]],
                           "otro": ["command": "/bin/echo"]],
        ])
        let command = MCPHealth.commandStored(in: data, client: MCPClient.all[0])
        #expect(command == ["/Users/x/Downloads/BeLauncher.app/Contents/MacOS/BeLauncher", "--mcp"])
    }

    @Test("un cliente que no nos menciona no tiene comando que probar")
    func sinEntradaNoHayComando() throws {
        let data = try JSONSerialization.data(withJSONObject: ["mcpServers": ["otro": ["command": "/bin/echo"]]])
        #expect(MCPHealth.commandStored(in: data, client: MCPClient.all[0]) == nil)
    }

    @Test("cada cliente se lee por su propia clave de servidores")
    func claveDeServidoresPorCliente() throws {
        let vscode = try #require(MCPClient.all.first { $0.id == "vscode" })
        let data = try JSONSerialization.data(withJSONObject: [
            "servers": ["belauncher": ["command": "/Applications/BeLauncher.app/Contents/MacOS/BeLauncher"]],
        ])
        #expect(MCPHealth.commandStored(in: data, client: vscode)?.first
            == "/Applications/BeLauncher.app/Contents/MacOS/BeLauncher")
        #expect(MCPHealth.commandStored(in: data, client: MCPClient.all[0]) == nil)
    }

    @Test("una configuración rota no revienta la lectura del comando")
    func configuracionRotaNoRevienta() {
        #expect(MCPHealth.commandStored(in: Data("{ roto".utf8), client: MCPClient.all[0]) == nil)
        #expect(MCPHealth.commandStored(in: nil, client: MCPClient.all[0]) == nil)
    }

    // MARK: - Esperar una línea sin colgarse

    @Test("una tubería muda se abandona al vencer el plazo, no se espera para siempre")
    @MainActor
    func tuberiaMudaSeAbandona() async {
        // Con la versión anterior esto no terminaba nunca: el read bloqueante no era cancelable y
        // el grupo de tareas esperaba a su hija antes de devolver, así que el plazo de 5 s no
        // existía, el proceso quedaba huérfano y «Comprobar» se quedaba deshabilitado.
        let feed = MCPHealth.LineFeed()
        var reloj = Date(timeIntervalSince1970: 0)
        var pausas = 0

        let outcome = await MCPHealth.nextLine(
            from: feed, deadline: Date(timeIntervalSince1970: 5), now: { reloj },
            peek: { .idle },
            pause: { pausas += 1; reloj = reloj.addingTimeInterval(1) })

        #expect(outcome == .timedOut)
        #expect(pausas == 5, "una pausa por segundo hasta el plazo, y ni una más")
    }

    @Test("una línea partida en trozos se recompone")
    @MainActor
    func lineaPartidaSeRecompone() async {
        let feed = MCPHealth.LineFeed()
        var trozos: [MCPHealth.PipePeek] = [
            .bytes(Data("{\"jsonrpc\"".utf8)), .idle, .bytes(Data(":\"2.0\"}\n{\"otra\"".utf8)),
        ]

        let outcome = await MCPHealth.nextLine(
            from: feed, deadline: Date().addingTimeInterval(60),
            peek: { trozos.isEmpty ? .idle : trozos.removeFirst() }, pause: {})

        #expect(outcome == .line("{\"jsonrpc\":\"2.0\"}"))
    }

    @Test("una línea ya completa gana al reloj vencido")
    @MainActor
    func lineaCompletaGanaAlReloj() async {
        // Los bytes llegaron a tiempo: comprobar el reloj antes que el buffer tiraría una
        // respuesta buena solo porque el plazo venció mientras se leía.
        let feed = MCPHealth.LineFeed()
        feed.append(Data("respuesta\n".utf8))

        let outcome = await MCPHealth.nextLine(
            from: feed, deadline: Date(timeIntervalSince1970: 0), peek: { .idle }, pause: {})

        #expect(outcome == .line("respuesta"))
    }

    @Test("si la tubería se cierra sin salto de línea, lo que quedaba se aprovecha")
    @MainActor
    func cierreDevuelveLoQueQuedaba() async {
        let feed = MCPHealth.LineFeed()
        var trozos: [MCPHealth.PipePeek] = [.bytes(Data("a medias".utf8)), .closed]

        let outcome = await MCPHealth.nextLine(
            from: feed, deadline: Date().addingTimeInterval(60),
            peek: { trozos.isEmpty ? .closed : trozos.removeFirst() }, pause: {})

        #expect(outcome == .line("a medias"))
    }

    @Test("una tubería que se cierra sin decir nada es un final, no un plazo agotado")
    @MainActor
    func cierreVacioEsFinal() async {
        let outcome = await MCPHealth.nextLine(
            from: MCPHealth.LineFeed(), deadline: Date().addingTimeInterval(60),
            peek: { .closed }, pause: {})

        #expect(outcome == .eof)
    }

    // MARK: - Cada modo de fallo nombra su paso y da un mensaje distinto

    @Test("cada paso que falla produce un mensaje distinto que lo nombra")
    func mensajesDistintosPorPaso() {
        let noConfigurado = MCPHealth.report(
            clientName: "x", configured: false, launch: nil,
            handshake: nil, toolsList: nil, toolCall: nil, echoing: Self.eco)
        let noArranca = MCPHealth.report(
            clientName: "x", configured: true, launch: .failed("no such file"),
            handshake: nil, toolsList: nil, toolCall: nil, echoing: Self.eco)
        let sinSaludo = MCPHealth.report(
            clientName: "x", configured: true, launch: .started,
            handshake: nil, toolsList: nil, toolCall: nil, echoing: Self.eco)
        let sinHerramientas = MCPHealth.report(
            clientName: "x", configured: true, launch: .started,
            handshake: Self.initializeReply(), toolsList: nil, toolCall: nil, echoing: Self.eco)

        let mensajes = [noConfigurado, noArranca, sinSaludo, sinHerramientas]
            .compactMap { $0.firstFailure?.outcome.reason }
        #expect(Set(mensajes).count == mensajes.count, "cada fallo debe decir algo distinto")

        #expect(noConfigurado.firstFailure?.step == .configured)
        #expect(noArranca.firstFailure?.step == .launched)
        #expect(sinSaludo.firstFailure?.step == .handshake)
        #expect(sinHerramientas.firstFailure?.step == .toolsListed)
    }

    @Test("el resumen de un cliente nombra el paso que rompió, no solo que algo falló")
    @MainActor
    func resumenNombraElPaso() async throws {
        let canary = MCPHealth.Canary.make()
        let context = MCPContext(vault: try vault(), store: try store())
        let vacia = try await reply(tool: "search_memory",
                                    arguments: ["query": canary.needle], context: context)

        let report = MCPHealth.report(
            clientName: "Cursor", configured: true, launch: .started,
            handshake: Self.initializeReply(), toolsList: Self.toolsListReply(names: ["recall"]),
            toolCall: vacia, echoing: canary.echo
        )
        #expect(report.summary.contains("Cursor"))
        #expect(report.summary.contains("Una llamada real trae datos"))
    }

    // MARK: - JSON malformado no revienta nada

    @Test("JSON malformado en el saludo se detecta sin lanzar")
    func jsonMalformadoEnSaludo() {
        let outcome = MCPHealth.evaluateHandshake("esto no es json{{{")
        guard case .failed = outcome else { Issue.record("debía fallar"); return }
    }

    @Test("JSON malformado en tools/list se detecta sin lanzar")
    func jsonMalformadoEnToolsList() {
        let outcome = MCPHealth.evaluateToolsList("<html>no</html>")
        guard case .failed = outcome else { Issue.record("debía fallar"); return }
    }

    @Test("JSON malformado en tools/call se detecta sin lanzar")
    func jsonMalformadoEnToolCall() {
        let outcome = MCPHealth.evaluateToolCall("{ roto", echoing: Self.eco)
        guard case .failed = outcome else { Issue.record("debía fallar"); return }
    }

    @Test("un error JSON-RPC explícito se reporta con su mensaje")
    func errorJsonRpcExplicito() {
        let outcome = MCPHealth.evaluateHandshake(Self.rpcError("boom interno"))
        guard case .failed(let reason) = outcome else { Issue.record("debía fallar"); return }
        #expect(reason.contains("boom interno"))
    }

    @Test("isError en el resultado de la llamada cuenta como fallo aunque haya contenido")
    func isErrorCuentaComoFallo() {
        let outcome = MCPHealth.evaluateToolCall(
            Self.toolCallReply(text: "\(Self.eco) detalle del error", isError: true),
            echoing: Self.eco)
        #expect(!outcome.isHealthy)
    }

    @Test("una respuesta sin protocolVersion no pasa por MCP válido")
    func sinProtocolVersionFalla() {
        let outcome = MCPHealth.evaluateHandshake(Self.initializeReply(protocolVersion: nil))
        #expect(!outcome.isHealthy)
    }

    // MARK: - Encadenado: un paso roto se salta lo que viene después

    @Test("si el proceso no arranca, los pasos siguientes se marcan como no comprobados")
    func fallosPosterioresSeSaltan() {
        let report = MCPHealth.report(
            clientName: "x", configured: true, launch: .failed("crash"),
            handshake: Self.initializeReply(), toolsList: Self.toolsListReply(names: ["y"]),
            toolCall: Self.toolCallReply(text: "esto no debería importar"), echoing: Self.eco
        )
        let handshakeStatus = report.steps.first { $0.step == .handshake }
        #expect(handshakeStatus?.outcome == .skipped, "no tiene sentido evaluar el saludo si el proceso ni arrancó")
    }

    @Test("si no está configurado, no se le atribuye ningún otro fallo")
    func noConfiguradoNoArrastraOtrosFallos() {
        let report = MCPHealth.report(
            clientName: "x", configured: false, launch: .started,
            handshake: Self.initializeReply(), toolsList: Self.toolsListReply(names: ["y"]),
            toolCall: Self.toolCallReply(text: "\(Self.eco) 42"), echoing: Self.eco
        )
        #expect(!report.isConnected)
        #expect(report.firstFailure?.step == .configured)
        let launchStatus = report.steps.first { $0.step == .launched }
        #expect(launchStatus?.outcome == .skipped)
    }

    // MARK: - El camino feliz, con el canario de verdad dando la vuelta entera

    @Test("los cinco pasos en verde sí cuentan como conectado")
    @MainActor
    func todoVerdeConecta() async throws {
        let canary = MCPHealth.Canary.make()
        let made = try store()
        plant(canary, in: made)
        let context = MCPContext(vault: try vault(), store: made, brain: BrainSearch(store: made))
        let raw = try await reply(tool: "recall",
                                  arguments: ["query": canary.needle, "limit": 20],
                                  context: context)

        let report = MCPHealth.report(
            clientName: "Claude Code", configured: true, launch: .started,
            handshake: Self.initializeReply(), toolsList: Self.toolsListReply(names: ["recall"]),
            toolCall: raw, echoing: canary.echo
        )
        #expect(report.isConnected)
        #expect(report.firstFailure == nil)
        #expect(report.steps.allSatisfy { $0.outcome.isHealthy })
    }

    // MARK: - Legible

    @Test("el informe se renderiza a texto legible, con el nombre del cliente y cada paso")
    func seRenderizaATextoLegible() {
        let sano = MCPHealth.report(
            clientName: "Claude Desktop", configured: true, launch: .started,
            handshake: Self.initializeReply(), toolsList: Self.toolsListReply(names: ["x"]),
            toolCall: Self.toolCallReply(text: "\(Self.eco) con su dato"), echoing: Self.eco)
        let roto = MCPHealth.report(
            clientName: "Cursor", configured: false, launch: nil,
            handshake: nil, toolsList: nil, toolCall: nil, echoing: Self.eco)

        let texto = MCPHealth.render([sano, roto])
        #expect(texto.contains("Claude Desktop"))
        #expect(texto.contains("Cursor"))
        #expect(texto.contains("conectado de verdad"))
        #expect(texto.contains("no conectado"))
        #expect(texto.contains("El asistente conoce a BeLauncher"))
    }
}
