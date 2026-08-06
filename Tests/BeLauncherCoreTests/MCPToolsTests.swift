import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Las herramientas MCP contra el cerebro de verdad")
@MainActor
struct MCPToolsTests {

    // MARK: - Andamiaje

    private func makeStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-mcp-\(UUID().uuidString)")
            .appendingPathComponent("s.sqlite3").path
        let store = try Store(path: path)
        try store.migrateSemanticIndex()
        return store
    }

    private func makeVault(_ objects: [MemoryObject] = []) throws -> Vault {
        let vault = try Vault(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-mcp-vault-\(UUID().uuidString)").path)
        try objects.forEach(vault.save)
        return vault
    }

    /// Un motor de embeddings falso pero coherente: todo lo que habla de dinero cae en un punto
    /// del espacio y el resto en otro. Es lo que permite comprobar que la vía por significado
    /// encuentra un pasaje que no comparte ni una palabra con la pregunta, sin depender de que
    /// haya un Ollama corriendo en la máquina donde se ejecutan las pruebas.
    private static func fakeEmbedder() -> Embedder {
        Embedder(transport: { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()))
                as? [String: Any]
            let inputs = (body?["input"] as? [String]) ?? []
            let money = ["precio", "tarifa", "cuesta", "cobramos", "euros", "factura"]
            let vectors = inputs.map { text -> [Double] in
                let folded = text.lowercased()
                return money.contains(where: { folded.contains($0) }) ? [1, 0] : [0, 1]
            }
            let data = try JSONSerialization.data(withJSONObject: ["embeddings": vectors])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200,
                                          httpVersion: nil, headerFields: nil)!)
        })
    }

    private static let fakeEngine = EmbeddingEngine(
        providerID: "ollama", name: "Ollama", shape: .ollama,
        endpoint: "http://localhost:11434/api/embed", model: "bge-m3:falso")

    /// Un cerebro con motor. Devuelve el índice ya vectorizado, como estaría en uso real.
    private func brain(store: Store, memories: [MemoryObject] = [], nodes: [WorkNode] = [],
                       clips: [Clip] = []) async throws -> BrainSearch {
        let brain = BrainSearch(store: store, embedder: Self.fakeEmbedder(),
                                engine: Self.fakeEngine)
        brain.index(memories: memories, nodes: nodes, clips: clips)
        _ = try await brain.embedEverything()
        return brain
    }

    /// Un cerebro sin motor: el índice existe, los vectores no.
    private func wordOnlyBrain(store: Store, memories: [MemoryObject] = [],
                               nodes: [WorkNode] = [], clips: [Clip] = []) -> BrainSearch {
        let brain = BrainSearch(store: store)
        brain.index(memories: memories, nodes: nodes, clips: clips)
        return brain
    }

    /// Un instante fijo al mediodía local.
    ///
    /// Las bandas de `what_was_i_doing` se calculan con `Calendar.isDate(inSameDayAs:)`, así que
    /// anclar la prueba en «ahora» la hacía fallar de verdad entre las 00:00 y la 01:00: «ahora
    /// menos una hora» caía en el día anterior y la banda «Hoy» no llegaba a existir. Un rojo que
    /// depende del reloj enseña a reintentar en vez de a mirar.
    private func mediodia() throws -> Date {
        try #require(Calendar.current.date(
            from: DateComponents(year: 2026, month: 6, day: 15, hour: 12)))
    }

    /// Dos credenciales con forma real: una en la frase, que es lo que renderizan las herramientas
    /// que leen el vault, y otra en el cuerpo, que es lo que se trocea en pasajes. Escrita a mano,
    /// como una nota de verdad: el filtro de captura solo mira el portapapeles, así que esto entra
    /// al cerebro por otra puerta.
    private func memoriaConCredenciales() -> MemoryObject {
        MemoryObject(
            level: .committed, kind: .decision,
            statement: "Las credenciales del despliegue de Acme: "
                     + "AWS_SECRET_ACCESS_KEY=AKIAIOSFODNN7EXAMPLEKEY0987654321",
            body: "La clave del agente es "
                + "sk-ant-api03-DEADBEEFDEADBEEFDEADBEEFDEADBEEF y no se rota desde marzo.",
            source: "Nota", owner: "Jorge", entities: ["Acme", "despliegue"])
    }

    private func decision(_ statement: String, body: String = "",
                          entities: [String] = ["pricing"]) -> MemoryObject {
        MemoryObject(level: .committed, kind: .decision, statement: statement, body: body,
                     source: "Reunión de producto", owner: "Jorge",
                     createdAt: .now.addingTimeInterval(-100),
                     validFrom: .now.addingTimeInterval(-100), entities: entities)
    }

    // MARK: - recall

    @Test("recall devuelve cada pasaje con su origen, su fecha y la vía por la que apareció")
    func recallCita() async throws {
        let store = try makeStore()
        let memoria = decision("El plan Pro cuesta 1000 euros al mes para cada empresa cliente.")
        let context = MCPContext(vault: try makeVault([memoria]), store: store,
                                 brain: try await brain(store: store, memories: [memoria]))

        let response = await MCPServer.call(name: "recall",
                                            arguments: ["query": "cuesta el plan Pro"],
                                            context: context)
        #expect(!response.isError)
        #expect(response.text.contains("[1]"))
        #expect(response.text.contains("Memory"), "una cita sin origen no es una cita")
        #expect(response.text.contains("1000"))
        // La fecha del pasaje, para que quien lea sepa si esto es de este trimestre o de 2019.
        #expect(response.text.contains(MCPTools.stamp(memoria.validFrom)))
    }

    @Test("recall encuentra por significado algo que no comparte ni una palabra con la pregunta")
    func recallPorSignificado() async throws {
        let store = try makeStore()
        let memoria = decision("El plan Pro cuesta 1000 euros al mes para cada empresa cliente.")
        let context = MCPContext(vault: try makeVault([memoria]), store: store,
                                 brain: try await brain(store: store, memories: [memoria]))

        // «tarifas» no aparece en el pasaje: si sale, ha salido por el vector y no por FTS.
        #expect(store.matchingWords("tarifas").isEmpty)
        let response = await MCPServer.call(name: "recall", arguments: ["query": "tarifas"],
                                            context: context)
        #expect(response.text.contains("1000"))
        #expect(response.text.contains("by meaning"))
    }

    @Test("sin motor de embeddings lo dice, en vez de dejar creer que no hay nada")
    func recallSinMotor() async throws {
        let store = try makeStore()
        let memoria = decision("El plan Pro cuesta 1000 euros al mes para cada empresa cliente.")
        let context = MCPContext(vault: try makeVault([memoria]), store: store,
                                 brain: wordOnlyBrain(store: store, memories: [memoria]))

        let response = await MCPServer.call(name: "recall", arguments: ["query": "cuesta el plan"],
                                            context: context)
        #expect(response.text.contains("by words only"))
        #expect(response.text.contains("embedding model"))
    }

    @Test("con el índice vacío dice qué buscó y dónde miró, no una frase genérica")
    func recallIndiceVacio() async throws {
        let store = try makeStore()
        let context = MCPContext(vault: try makeVault(), store: store,
                                 brain: wordOnlyBrain(store: store))

        let response = await MCPServer.call(name: "recall",
                                            arguments: ["query": "precios de enterprise"],
                                            context: context)
        #expect(response.text.contains("precios de enterprise"))
        #expect(response.text.contains("deliberate memory (0 object(s))"))
        #expect(response.text.contains("0 passage(s)"))
    }

    // MARK: - context_for

    @Test("context_for agrupa por origen y marca dónde empieza y acaba la cita textual")
    func contextForAgrupa() async throws {
        let store = try makeStore()
        let memoria = decision("El plan Pro cuesta 1000 euros al mes para cada empresa cliente.")
        let clip = Clip(id: 1, text: "La propuesta de Acme repite el precio del plan Pro en la "
                                   + "página tres y contradice la página uno.",
                        createdAt: .now)
        let context = MCPContext(vault: try makeVault([memoria]), store: store,
                                 brain: try await brain(store: store, memories: [memoria],
                                                        clips: [clip]))

        let response = await MCPServer.call(name: "context_for",
                                            arguments: ["task": "rehacer la propuesta de precios"],
                                            context: context)
        #expect(response.text.hasPrefix("<context_for"))
        #expect(response.text.contains("<source kind=\"Memory\""))
        #expect(response.text.contains("<source kind=\"Clipboard\""))
        #expect(response.text.contains("<quote n=\"1\">"))
        #expect(response.text.contains("</quote>"))
        #expect(response.text.contains("<how_to_use_this>"))
        // La fecha va en formato de máquina: quien lee esto es otro modelo, no una persona.
        #expect(response.text.contains("fecha=\"\(MCPTools.isoDay(memoria.validFrom))\""))
    }

    @Test("context_for numera las citas de forma única en todo el documento")
    func contextForNumeracion() async throws {
        let store = try makeStore()
        let largo = String(repeating: "El precio del plan Pro se revisa cada trimestre y la "
                                    + "revisión la firma el comité. ", count: 14)
        let memoria = decision("Revisión trimestral de precios", body: largo)
        let context = MCPContext(vault: try makeVault([memoria]), store: store,
                                 brain: try await brain(store: store, memories: [memoria]))

        let response = await MCPServer.call(name: "context_for",
                                            arguments: ["task": "revisar el precio del Pro"],
                                            context: context)
        let numeros = response.text
            .components(separatedBy: "<quote n=\"")
            .dropFirst()
            .compactMap { Int($0.prefix(while: { $0.isNumber })) }
        #expect(numeros.count >= 2, "el texto largo tiene que trocearse en varias citas")
        #expect(numeros == Array(1...numeros.count))
    }

    @Test("context_for deja el texto citado tal cual, sin escaparlo")
    func contextForTextoLiteral() async throws {
        let store = try makeStore()
        let memoria = decision("La plantilla del correo lleva <strong>precio</strong> & "
                             + "la firma completa al final de cada envío que sale.")
        let context = MCPContext(vault: try makeVault([memoria]), store: store,
                                 brain: try await brain(store: store, memories: [memoria]))

        let response = await MCPServer.call(name: "context_for",
                                            arguments: ["task": "rehacer la plantilla del correo"],
                                            context: context)
        // Un documento que se va a reescribir no puede volver con su marcado convertido en
        // entidades: lo que se cita se cita entero o no sirve.
        #expect(response.text.contains("<strong>precio</strong> &"))
    }

    // MARK: - what_was_i_doing

    @Test("what_was_i_doing reparte por tramos y marca lo que es cita textual")
    func loUltimoTrabajado() throws {
        let store = try makeStore()
        let ahora = try mediodia()
        store.upsertNode(WorkNode(id: "file:mcp", kind: .file, name: "MCPServer.swift",
                                  detail: "Sources/BeLauncherCore",
                                  lastSeen: ahora.addingTimeInterval(-3_600)))
        store.upsertNode(WorkNode(id: "meeting:acme", kind: .meeting, name: "Repaso con Acme",
                                  detail: "cuatro asistentes",
                                  lastSeen: ahora.addingTimeInterval(-30 * 3_600)))
        store.recordClip(text: "el pipeline de retrieval ya cita la fuente de cada pasaje",
                         sourceApp: "Terminal", at: ahora.addingTimeInterval(-7_200))

        let context = MCPContext(vault: try makeVault(), store: store)
        let response = MCPTools.whatWasIDoing(since: "7d", context: context, date: ahora)

        #expect(response.text.contains("## Today"))
        #expect(response.text.contains("## Yesterday"))
        #expect(response.text.contains("MCPServer.swift"))
        #expect(response.text.contains("Repaso con Acme"))
        #expect(response.text.contains("Clipboard (verbatim quote)"))
        #expect(response.text.contains("work graph (2 node(s))"))
    }

    @Test("un tramo sin actividad dice qué miró y cómo ampliarlo")
    func tramoVacio() throws {
        let store = try makeStore()
        let ahora = Date()
        store.upsertNode(WorkNode(id: "file:viejo", kind: .file, name: "viejo.txt",
                                  lastSeen: ahora.addingTimeInterval(-30 * 86_400)))

        let context = MCPContext(vault: try makeVault(), store: store)
        let response = MCPTools.whatWasIDoing(since: "1h", context: context, date: ahora)

        #expect(response.text.contains("work graph (0 node(s))"))
        #expect(response.text.contains("clipboard (0 fragment(s))"))
        #expect(response.text.contains("7d"),
                "decir que no hay nada sin decir cómo ampliar el tramo obliga a adivinar")
    }

    // MARK: - what_did_we_decide y prepare

    @Test("what_did_we_decide separa la decisión vigente del contexto que la rodea")
    func decisionMasContexto() async throws {
        let store = try makeStore()
        let memoria = decision("Precio enterprise: 2000 euros al año")
        let clip = Clip(id: 2, text: "Acme pidió que el precio enterprise se facture por "
                                   + "adelantado y en una sola factura anual.", createdAt: .now)
        let context = MCPContext(vault: try makeVault([memoria]), store: store,
                                 brain: try await brain(store: store, memories: [memoria],
                                                        clips: [clip]))

        let response = await MCPServer.call(name: "what_did_we_decide",
                                            arguments: ["topic": "precio enterprise"],
                                            context: context)
        #expect(response.text.contains("2000"))
        #expect(response.text.contains("Fuentes:"))
        #expect(response.text.contains("not recorded decisions"))
        #expect(response.text.contains("adelantado"), "el índice tenía material y no salió")
    }

    @Test("sin decisión registrada dice exactamente qué buscó y dónde miró")
    func sinDecision() async throws {
        let store = try makeStore()
        let clip = Clip(id: 3, text: "En el hilo de soporte se habló del precio enterprise pero "
                                   + "nadie cerró nada por escrito todavía.", createdAt: .now)
        let context = MCPContext(vault: try makeVault(), store: store,
                                 brain: try await brain(store: store, clips: [clip]))

        let response = await MCPServer.call(name: "what_did_we_decide",
                                            arguments: ["topic": "precio enterprise"],
                                            context: context)
        #expect(response.text.contains("No decision is recorded"))
        #expect(response.text.contains("I searched for “precio enterprise”"))
        #expect(response.text.contains("semantic index"))
        #expect(response.text.contains("treat it as context and not as the answer"))
    }

    @Test("prepare suma lo indexado a lo que hay en el vault")
    func prepararConIndice() async throws {
        let store = try makeStore()
        let memoria = MemoryObject(level: .committed, kind: .commitment,
                                   statement: "Enviar a Acme la propuesta revisada el viernes",
                                   source: "Llamada", owner: "Jorge", entities: ["Acme"])
        let clip = Clip(id: 4, text: "Acme insiste en que la propuesta incluya el desglose de "
                                   + "horas por perfil y no solo el total.", createdAt: .now)
        let context = MCPContext(vault: try makeVault([memoria]), store: store,
                                 brain: try await brain(store: store, memories: [memoria],
                                                        clips: [clip]))

        let response = await MCPServer.call(name: "prepare", arguments: ["subject": "Acme"],
                                            context: context)
        #expect(response.text.contains("propuesta revisada el viernes"))
        #expect(response.text.contains("From what is indexed"))
        #expect(response.text.contains("desglose de horas"))
        #expect(response.text.contains("Clipboard"))
    }

    // MARK: - Lo que no puede pasar

    @Test("nada con pinta de credencial sale por recall")
    func credencialesNoSalenPorRecall() async throws {
        let store = try makeStore()
        // Una memoria escrita a mano esquiva el filtro del portapapeles: entra al índice por otra
        // puerta, así que la comprobación tiene que estar también a la salida.
        let memoria = MemoryObject(
            level: .committed, kind: .note,
            statement: "Credenciales del despliegue de Acme",
            body: "AWS_SECRET_ACCESS_KEY=AKIAIOSFODNN7EXAMPLEKEY0987654321\n"
                + "Están también en el gestor de contraseñas del equipo.",
            source: "Nota")
        let context = MCPContext(vault: try makeVault([memoria]), store: store,
                                 brain: try await brain(store: store, memories: [memoria]))

        let response = await MCPServer.call(name: "recall",
                                            arguments: ["query": "credenciales del despliegue"],
                                            context: context)
        #expect(!response.text.contains("AKIAIOSFODNN7EXAMPLEKEY"))
        #expect(!response.text.contains("AWS_SECRET_ACCESS_KEY"))
    }

    @Test("nada con pinta de credencial sale por search_memory, y el resto de la lista sí sale")
    func credencialesNoSalenPorSearchMemory() async throws {
        let store = try makeStore()
        let limpia = MemoryObject(level: .committed, kind: .decision,
                                  statement: "Acme firma la renovación en septiembre",
                                  source: "Llamada", entities: ["Acme"])
        let context = MCPContext(vault: try makeVault([memoriaConCredenciales(), limpia]),
                                 store: store)

        let response = await MCPServer.call(name: "search_memory",
                                            arguments: ["query": "Acme"], context: context)
        #expect(!response.text.contains("AKIAIOSFODNN7EXAMPLEKEY"))
        #expect(!response.text.contains("AWS_SECRET_ACCESS_KEY"))
        // Tapar la línea, no vaciar la respuesta: si el filtro se comiera la lista entera, la
        // herramienta contestaría «no hay nada» sobre una memoria que sí existe.
        #expect(response.text.contains("renovación en septiembre"))
        #expect(response.text.contains(MCPTools.redactionMark),
                "quitar algo sin decirlo deja al modelo leyendo un hueco que no ve")
    }

    @Test("nada con pinta de credencial sale por what_did_we_decide")
    func credencialesNoSalenPorWhatDidWeDecide() async throws {
        let memoria = memoriaConCredenciales()
        let store = try makeStore()
        let context = MCPContext(vault: try makeVault([memoria]), store: store,
                                 brain: try await brain(store: store, memories: [memoria]))

        let response = await MCPServer.call(
            name: "what_did_we_decide",
            arguments: ["topic": "credenciales del despliegue"], context: context)
        #expect(!response.text.contains("AKIAIOSFODNN7EXAMPLEKEY"))
        #expect(!response.text.contains("AWS_SECRET_ACCESS_KEY"))
        #expect(!response.text.contains("sk-ant-api03-"))
    }

    @Test("nada con pinta de credencial sale por prepare")
    func credencialesNoSalenPorPrepare() async throws {
        let memoria = memoriaConCredenciales()
        let store = try makeStore()
        let context = MCPContext(vault: try makeVault([memoria]), store: store,
                                 brain: try await brain(store: store, memories: [memoria]))

        let response = await MCPServer.call(name: "prepare", arguments: ["subject": "Acme"],
                                            context: context)
        #expect(!response.text.contains("AKIAIOSFODNN7EXAMPLEKEY"))
        #expect(!response.text.contains("AWS_SECRET_ACCESS_KEY"))
        #expect(!response.text.contains("sk-ant-api03-"))
    }

    @Test("un nodo del grafo bautizado como una línea de .env tampoco sale")
    func credencialesNoSalenPorElGrafoDeTrabajo() throws {
        let store = try makeStore()
        let ahora = try mediodia()
        // El nombre y el detalle van en medio de una línea ya formateada, con la hora delante. Los
        // dos primeros ':' de «12:00 · Archivo · …» son lo que despista a una comprobación de
        // línea entera, así que el campo tiene que mirarse por separado.
        store.upsertNode(WorkNode(id: "file:env", kind: .file,
                                  name: "AWS_SECRET_ACCESS_KEY=AKIAIOSFODNN7EXAMPLEKEY0987654321",
                                  detail: "sk-ant-api03-DEADBEEFDEADBEEFDEADBEEFDEADBEEF",
                                  lastSeen: ahora.addingTimeInterval(-3_600)))
        store.upsertNode(WorkNode(id: "file:mcp", kind: .file, name: "MCPTools.swift",
                                  lastSeen: ahora.addingTimeInterval(-1_800)))

        let context = MCPContext(vault: try makeVault(), store: store)
        let response = MCPTools.whatWasIDoing(since: "7d", context: context, date: ahora)

        #expect(!response.text.contains("AKIAIOSFODNN7EXAMPLEKEY"))
        #expect(!response.text.contains("AWS_SECRET_ACCESS_KEY"))
        #expect(!response.text.contains("sk-ant-api03-"))
        #expect(response.text.contains("MCPTools.swift"), "el resto del tramo sigue siendo útil")
        #expect(response.text.contains(MCPTools.redactionMark))
    }

    @Test("la pregunta que trae una credencial no vuelve con ella")
    func credencialesNoVuelvenEnElEco() async throws {
        let store = try makeStore()
        let context = MCPContext(vault: try makeVault(), store: store)
        let token = "sk-ant-api03-DEADBEEFDEADBEEFDEADBEEFDEADBEEF"

        // Todas estas herramientas repiten el argumento en la respuesta («Busqué «X»…»,
        // tarea="X"). Si el modelo pega una clave en la pregunta, repetírsela la manda otra vez
        // por el cable y la deja escrita en su historial.
        for nombre in ["recall", "context_for", "what_did_we_decide", "prepare", "search_memory"] {
            let argumento = ["recall": "query", "context_for": "task", "what_did_we_decide": "topic",
                             "prepare": "subject", "search_memory": "query"][nombre]!
            let response = await MCPServer.call(name: nombre,
                                                arguments: [argumento: "la clave \(token)"],
                                                context: context)
            #expect(!response.text.contains(token), "\(nombre) devuelve la credencial que le dieron")
        }
    }

    @Test("el filtro mira la línea entera, y aun así deja pasar el texto normal")
    func elFiltroNoEsUnaEscoba() {
        // Lo que tiene que caer: la decoración de la línea es justo lo que despistaba al guardia,
        // porque solo leía la primera palabra y el primer «=» o «:» de lo que le daban.
        #expect(MCPTools.carriesSecret("**sk-ant-api03-DEADBEEFDEADBEEFDEADBEEFDEADBEEF**"))
        #expect(MCPTools.carriesSecret("- 12:00 · Archivo · AKIAIOSFODNN7EXAMPLEKEY0987654321"))
        #expect(MCPTools.carriesSecret(
            "El fichero trae AWS_SECRET_ACCESS_KEY=AKIAIOSFODNN7EXAMPLEKEY0987654321 al final."))

        // Lo que no puede caer. Un filtro que se lleva por delante una frase normal deja al
        // asistente contestando «no hay nada» sobre memoria que sí existe, que es el fallo que
        // este archivo entero intenta no cometer.
        for linea in ["El plan Pro cuesta 1000 euros al mes para cada empresa cliente.",
                      "Reunión a las 15:30 con el equipo de plataforma.",
                      "El endpoint es http://localhost:11434/api/embed y va sin autenticación.",
                      "Hay que rotar el token de GitHub antes del viernes.",
                      "- 12:00 · Archivo · MCPTools.swift — Sources/BeLauncherCore",
                      "La estrategia de precios se revisa cada trimestre."] {
            #expect(!MCPTools.carriesSecret(linea), "se comió una línea legítima: \(linea)")
        }
    }

    @Test("propose_memory sigue proponiendo y solo proponiendo")
    func soloPropone() async throws {
        let store = try makeStore()
        let vault = try makeVault()
        let context = MCPContext(vault: vault, store: store)

        let response = await MCPServer.call(
            name: "propose_memory",
            arguments: ["statement": "El cliente pidió facturación anual", "kind": "commitment"],
            context: context)
        #expect(!response.isError)
        #expect(response.text.contains("has to confirm it"))
        #expect(vault.current().isEmpty, "nada entró en el cerebro sin una persona")
        #expect(vault.commits(state: .proposed).count == 1)
        #expect(!MCPServer.tools.contains { $0.name.contains("confirm") })
        #expect(!MCPServer.tools.contains { $0.name.contains("delete") })
    }

    @Test("una herramienta inexistente devuelve error y dice cuáles hay")
    func herramientaInexistente() async throws {
        let store = try makeStore()
        let context = MCPContext(vault: try makeVault(), store: store)

        let response = await MCPServer.call(name: "borrar_todo", arguments: [:], context: context)
        #expect(response.isError)
        #expect(response.text.contains("borrar_todo"))
        #expect(response.text.contains("recall"))
        #expect(response.text.contains("context_for"))
    }

    @Test("los argumentos que faltan se rechazan, nunca se adivinan")
    func argumentosQueFaltan() async throws {
        let store = try makeStore()
        let context = MCPContext(vault: try makeVault(), store: store)

        #expect(await MCPServer.call(name: "recall", arguments: [:], context: context).isError)
        #expect(await MCPServer.call(name: "context_for", arguments: ["task": "   "],
                                     context: context).isError)
        #expect(await MCPServer.call(name: "what_did_we_decide", arguments: [:],
                                     context: context).isError)
    }

    @Test("el JSON-RPC que sale es válido y lleva el mismo id que entró")
    func sobreJSONRPC() async throws {
        let store = try makeStore()
        let memoria = decision("El plan Pro cuesta 1000 euros al mes para cada empresa cliente.")
        let context = MCPContext(vault: try makeVault([memoria]), store: store,
                                 brain: try await brain(store: store, memories: [memoria]))

        let response = try #require(await MCPServer.handle([
            "jsonrpc": "2.0", "id": 42, "method": "tools/call",
            "params": ["name": "recall", "arguments": ["query": "cuesta el plan Pro"]],
        ], context: context))

        #expect(response["jsonrpc"] as? String == "2.0")
        #expect(response["id"] as? Int == 42)
        #expect(JSONSerialization.isValidJSONObject(response))
        let result = try #require(response["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "text")
        #expect((content.first?["text"] as? String)?.contains("1000") == true)
        #expect(result["isError"] as? Bool == false)
    }

    @Test("las siete herramientas se anuncian con un esquema que un modelo puede rellenar")
    func catalogo() async throws {
        let store = try makeStore()
        let context = MCPContext(vault: try makeVault(), store: store)
        let response = try #require(await MCPServer.handle(
            ["jsonrpc": "2.0", "id": 1, "method": "tools/list"], context: context))
        let tools = try #require((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])

        let nombres = tools.compactMap { $0["name"] as? String }
        #expect(Set(nombres) == ["recall", "context_for", "what_was_i_doing", "what_did_we_decide",
                                 "prepare", "search_memory", "propose_memory"])
        for tool in tools {
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect(schema["properties"] != nil)
            #expect((tool["description"] as? String)?.isEmpty == false)
        }
    }

    // MARK: - Detalles que se rompen solos

    @Test("«since» acepta lo que un modelo mandaría, y lo raro no rompe la llamada")
    func desdeCuando() {
        let ahora = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(MCPTools.moment("24h", now: ahora) == ahora.addingTimeInterval(-86_400))
        #expect(MCPTools.moment("7d", now: ahora) == ahora.addingTimeInterval(-7 * 86_400))
        #expect(MCPTools.moment("hoy", now: ahora) == Calendar.current.startOfDay(for: ahora))
        #expect(MCPTools.moment(nil, now: ahora) == ahora.addingTimeInterval(-86_400))
        // «0d» es «desde ahora mismo», no «no te he entendido»: caía al fallback y devolvía un día
        // entero de historial a quien había pedido explícitamente cero.
        #expect(MCPTools.moment("0d", now: ahora) == ahora)
        #expect(MCPTools.moment("0h", now: ahora) == ahora)
        // Un tramo negativo sí es un sinsentido y sigue cayendo al día por defecto.
        #expect(MCPTools.moment("-3d", now: ahora) == ahora.addingTimeInterval(-86_400))
        // Un formato que no se entiende cae a un día, no a un error: obligar a reintentar por el
        // formato de un argumento opcional convierte una respuesta útil en dos llamadas.
        #expect(MCPTools.moment("el martes pasado", now: ahora) == ahora.addingTimeInterval(-86_400))
    }

    @Test("el límite se acota en vez de vaciar la base entera en la respuesta")
    func limiteAcotado() {
        #expect(MCPTools.clamp(nil) == MCPTools.defaultLimit)
        #expect(MCPTools.clamp(500) == MCPTools.maximumLimit)
        #expect(MCPTools.clamp(0) == 1)
        #expect(MCPTools.clamp(5) == 5)
    }
}
