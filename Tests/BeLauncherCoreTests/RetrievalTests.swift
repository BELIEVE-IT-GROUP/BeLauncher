import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Elegir motor de embeddings")
struct EmbeddingEngineTests {

    @Test("Prefiere el modelo que mejor respondió en las pruebas, no el primero de la lista")
    func ranking() {
        let engine = EmbeddingEngine.best(
            localModels: ["ollama": ["nomic-embed-text:latest", "bge-m3:latest", "qwen2.5:latest"]],
            hostedKeyAvailable: false
        )
        #expect(engine?.model == "bge-m3:latest")
    }

    @Test("Los modelos de chat no se confunden con los de embeddings")
    func chatModelsIgnored() {
        #expect(EmbeddingEngine.best(localModels: ["ollama": ["llama3.2", "qwen2.5"]],
                                     hostedKeyAvailable: false) == nil)
    }

    @Test("Un modelo local gana siempre a uno en la nube, aunque haya clave")
    func localWins() {
        let engine = EmbeddingEngine.best(localModels: ["ollama": ["bge-m3"]],
                                          hostedKeyAvailable: true)
        #expect(engine?.isLocal == true)
    }

    @Test("Sin modelo local y con clave, se ofrece el de la nube")
    func hostedFallback() {
        let engine = EmbeddingEngine.best(localModels: [:], hostedKeyAvailable: true)
        #expect(engine?.isLocal == false)
        #expect(engine?.keychainAccount == "openai")
    }

    @Test("Sin nada, no hay motor y no se inventa uno")
    func nothing() {
        #expect(EmbeddingEngine.best(localModels: [:], hostedKeyAvailable: false) == nil)
    }
}

@Suite("Leer la respuesta del modelo")
struct EmbedderParsingTests {

    @Test("Formato Ollama")
    func ollama() throws {
        let data = Data(#"{"embeddings":[[0.1,0.2],[0.3,0.4]]}"#.utf8)
        let vectors = try Embedder.parse(data, shape: .ollama)
        #expect(vectors.count == 2)
        #expect(vectors[1] == [0.3, 0.4])
    }

    @Test("Formato OpenAI, respetando el índice que declara y no el orden de llegada")
    func openAIOutOfOrder() throws {
        let data = Data(#"{"data":[{"index":1,"embedding":[9]},{"index":0,"embedding":[1]}]}"#.utf8)
        let vectors = try Embedder.parse(data, shape: .openAI)
        #expect(vectors.map(\.first) == [1, 9])
    }

    @Test("Una respuesta corta se rechaza en vez de emparejar mal los pasajes")
    func countMismatch() async {
        let embedder = Embedder(transport: { _ in
            (Data(#"{"embeddings":[[1,0]]}"#.utf8),
             HTTPURLResponse(url: URL(string: "http://x")!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!)
        })
        let engine = EmbeddingEngine(providerID: "ollama", name: "Ollama", shape: .ollama,
                                     endpoint: "http://x", model: "bge-m3")
        await #expect(throws: EmbeddingError.countMismatch(sent: 2, received: 1)) {
            _ = try await embedder.embed(["uno", "dos"], using: engine)
        }
    }

    @Test("Los vectores devueltos vienen ya normalizados")
    func normalised() async throws {
        let embedder = Embedder(transport: { _ in
            (Data(#"{"embeddings":[[3,4]]}"#.utf8),
             HTTPURLResponse(url: URL(string: "http://x")!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!)
        })
        let engine = EmbeddingEngine(providerID: "ollama", name: "Ollama", shape: .ollama,
                                     endpoint: "http://x", model: "bge-m3")
        let vector = try await embedder.embed(["uno"], using: engine)[0]
        #expect(abs(sqrt(vector.reduce(0) { $0 + $1 * $1 }) - 1) < 1e-5)
    }

    /// Recorder rather than a captured var: the transport is `@Sendable` and runs off this
    /// actor, so a plain local would be a data race the compiler is right to refuse.
    private final class Recorder: @unchecked Sendable {
        var sent = false
    }

    @Test("Un motor en la nube sin clave falla antes de enviar nada")
    func missingKey() async {
        let recorder = Recorder()
        let embedder = Embedder(transport: { _ in
            recorder.sent = true
            return (Data(), URLResponse())
        }, keyLookup: { _ in nil })
        let engine = EmbeddingEngine(providerID: "openai", name: "OpenAI", shape: .openAI,
                                     endpoint: "http://x", model: "m", keychainAccount: "openai")
        await #expect(throws: EmbeddingError.missingKey("OpenAI")) {
            _ = try await embedder.embed(["uno"], using: engine)
        }
        #expect(recorder.sent == false)
    }
}

@Suite("Recuperar")
struct RetrieverTests {

    private func passage(_ id: String, _ text: String,
                         kind: IndexedSource.Kind = .memory) -> IndexedPassage {
        IndexedPassage(id: id, source: IndexedSource(kind: kind, id: id), title: text,
                       ordinal: 0, text: text, occurredAt: .now)
    }

    @Test("Lo que aciertan las dos vías se marca como tal y va primero")
    func both() {
        let result = Retriever.retrieve(
            query: "precio del plan",
            queryVector: [1, 0],
            nearest: { _ in [("a", 0.8), ("b", 0.5)] },
            words: { _ in ["a", "c"] },
            passage: { self.passage($0, "texto \($0)") }
        )
        #expect(result.hits.first?.id == "a")
        #expect(result.hits.first?.route == .both)
    }

    @Test("Un parecido flojo no entra: mejor no responder que responder cualquier cosa")
    func floor() {
        let result = Retriever.retrieve(
            query: "algo muy concreto",
            queryVector: [1, 0],
            nearest: { _ in [("ruido", 0.2)] },
            words: { _ in [] },
            passage: { self.passage($0, "texto") }
        )
        #expect(result.hits.isEmpty)
        #expect(result.gap != nil)
    }

    @Test("Sin vectores sigue buscando por palabras y lo dice")
    func wordsOnly() {
        let result = Retriever.retrieve(
            query: "factura 2024",
            queryVector: [],
            nearest: { _ in [] },
            words: { _ in ["a"] },
            passage: { self.passage($0, "la factura 2024") }
        )
        #expect(result.hits.count == 1)
        #expect(result.usedMeaning == false)
        #expect(result.gap?.contains("embeddings") == true)
    }

    @Test("El grafo trae lo relacionado aunque su texto no diga nada del tema")
    func graphHop() {
        let hit = passage("reunion", "reunión con Acme el jueves", kind: .node)
        let neighbour = IndexedSource(kind: .node, id: "compromiso")
        let result = Retriever.retrieve(
            query: "qué pasó con Acme",
            queryVector: [1, 0],
            nearest: { _ in [("reunion", 0.9)] },
            words: { _ in [] },
            passage: { $0 == "reunion" ? hit : nil },
            related: { _ in [neighbour] },
            passages: { _ in [self.passage("compromiso", "enviar la propuesta el viernes", kind: .node)] }
        )
        #expect(result.hits.contains { $0.route == .related })
        #expect(result.hits.contains { $0.passage.text.contains("propuesta") })
        // Y dice por dónde llegó, para que nadie tenga que adivinar de dónde salió.
        #expect(result.hits.first { $0.route == .related }?.via == hit.title)
    }

    @Test("Lo relacionado no repite lo que ya se encontró por otra vía")
    func noDuplicates() {
        let result = Retriever.retrieve(
            query: "acme y su propuesta",
            queryVector: [1, 0],
            nearest: { _ in [("a", 0.9)] },
            words: { _ in [] },
            passage: { self.passage($0, "texto \($0)") },
            related: { _ in [IndexedSource(kind: .memory, id: "a")] },
            passages: { _ in [self.passage("a", "texto a")] }
        )
        #expect(result.hits.map(\.id).count == Set(result.hits.map(\.id)).count)
    }

    @Test("Una consulta de dos letras no dispara nada")
    func tooShort() {
        var asked = false
        let result = Retriever.retrieve(
            query: "ac", queryVector: [1, 0],
            nearest: { _ in asked = true; return [] },
            words: { _ in [] }, passage: { _ in nil }
        )
        #expect(result.hits.isEmpty)
        #expect(asked == false)
    }

    @Test("El prompt numera las fuentes y prohíbe inventar")
    func prompt() {
        let hits = [Retrieved(passage: passage("a", "el precio es 1000"), score: 1, route: .meaning)]
        let (system, user) = Retriever.prompt(for: "cuánto cobramos", hits: hits)
        #expect(system.contains("No consta"))
        #expect(user.contains("[1]"))
        #expect(user.contains("el precio es 1000"))
    }
}

@Suite("Qué entra en el índice")
struct IndexerTests {

    @Test("Una memoria lleva su frase delante, que es lo que mejor se recupera")
    func memoryOrder() {
        let object = MemoryObject(level: .committed, kind: .decision,
                                  statement: "el precio del Pro sube a 59",
                                  body: "acordado en la reunión de septiembre")
        let item = Indexer.items(memories: [object])[0]
        #expect(item.text.hasPrefix("el precio del Pro sube a 59"))
        #expect(item.title == object.statement)
    }

    @Test("Un clip corto no gasta un vector")
    func shortClip() {
        let clip = Clip(id: 1, text: "ok")
        #expect(Indexer.items(clips: [clip]).isEmpty)
    }

    @Test("Nada con pinta de credencial entra en el índice")
    func secretsExcluded() {
        let secret = Clip(id: 2, text: "sk_live_" + String(repeating: "a", count: 64))
        #expect(Indexer.items(clips: [secret]).isEmpty)
    }

    @Test("Un nodo que solo repite su propio nombre no aporta nada")
    func thinNode() {
        let node = WorkNode(id: "n", kind: .file, name: "a.txt")
        #expect(Indexer.items(nodes: [node]).isEmpty)
    }

    @Test("Lo que ya no existe se quita del índice")
    func removals() {
        let gone = Indexer.removals(indexed: ["memory:a", "memory:b"], current: ["memory:a"])
        #expect(gone.map(\.id) == ["b"])
    }
}

@Suite("El índice en disco")
@MainActor
struct SemanticIndexTests {

    private func makeStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-index-\(UUID().uuidString)")
            .appendingPathComponent("s.sqlite3").path
        let store = try Store(path: path)
        try store.migrateSemanticIndex()
        return store
    }

    @Test("Guardar, buscar por palabra y recuperar el pasaje")
    func roundTrip() throws {
        let store = try makeStore()
        let source = IndexedSource(kind: .memory, id: "m1")
        let written = store.replacePassages(for: source, title: "Precios", occurredAt: .now,
                                            text: "El precio base del plan Pro es 1000 euros al mes.")
        #expect(written.count == 1)
        #expect(store.matchingWords("precio").count == 1)
        #expect(store.passage(id: written[0].id)?.title == "Precios")
    }

    @Test("Sin acentos también encuentra")
    func diacritics() throws {
        let store = try makeStore()
        _ = store.replacePassages(for: IndexedSource(kind: .node, id: "n1"), title: "Reunión",
                                  occurredAt: .now,
                                  text: "La reunión con Acme quedó movida al jueves por la mañana.")
        #expect(!store.matchingWords("reunion").isEmpty)
    }

    @Test("Volver a indexar el mismo texto conserva los vectores")
    func keepsVectors() throws {
        let store = try makeStore()
        let source = IndexedSource(kind: .memory, id: "m2")
        let text = "Los secretos nunca van a git, van a Infisical, sin excepción alguna."
        let first = store.replacePassages(for: source, title: "Regla", occurredAt: .now, text: text)
        store.storeVector([1, 0, 0], for: first[0].id, model: "bge-m3")

        _ = store.replacePassages(for: source, title: "Regla", occurredAt: .now, text: text)
        #expect(store.indexedPassageCount().vectorised == 1)
        #expect(store.passagesNeedingVectors(model: "bge-m3").isEmpty)
    }

    @Test("Cambiar de modelo invalida los vectores en vez de mezclar dos espacios")
    func modelChange() throws {
        let store = try makeStore()
        let source = IndexedSource(kind: .memory, id: "m3")
        let written = store.replacePassages(for: source, title: "Algo", occurredAt: .now,
                                            text: "Una frase suficientemente larga para indexarse entera.")
        store.storeVector([1, 0], for: written[0].id, model: "bge-m3")
        #expect(store.passagesNeedingVectors(model: "otro-modelo").count == 1)
    }

    @Test("Editar el texto borra los pasajes viejos, no los deja huérfanos")
    func edit() throws {
        let store = try makeStore()
        let source = IndexedSource(kind: .note, id: "n2")
        _ = store.replacePassages(for: source, title: "Nota", occurredAt: .now,
                                  text: "La primera versión de esta nota hablaba de otra cosa distinta.")
        _ = store.replacePassages(for: source, title: "Nota", occurredAt: .now,
                                  text: "La segunda versión de esta nota ya habla del asunto correcto.")
        #expect(store.matchingWords("primera").isEmpty)
        #expect(!store.matchingWords("segunda").isEmpty)
    }

    @Test("Borrar una fuente la saca también del buscador de palabras")
    func removal() throws {
        let store = try makeStore()
        let source = IndexedSource(kind: .clip, id: "c1")
        _ = store.replacePassages(for: source, title: "Clip", occurredAt: .now,
                                  text: "Un texto copiado con longitud más que suficiente para el índice.")
        store.removePassages(for: source)
        #expect(store.matchingWords("copiado").isEmpty)
        #expect(store.indexedPassageCount().total == 0)
    }

    @Test("Los vectores sobreviven al viaje de ida y vuelta a la base")
    func vectorPersistence() throws {
        let store = try makeStore()
        let source = IndexedSource(kind: .memory, id: "m4")
        let written = store.replacePassages(for: source, title: "T", occurredAt: .now,
                                            text: "Otra frase larga que sirve perfectamente de pasaje.")
        let vector = Semantic.normalise((0..<512).map { Float($0) * 0.01 - 2 })
        store.storeVector(vector, for: written[0].id, model: "bge-m3")

        let nearest = store.nearest(to: vector, limit: 1)
        #expect(nearest.first?.id == written[0].id)
        #expect(abs((nearest.first?.similarity ?? 0) - 1) < 1e-4)
    }
}
