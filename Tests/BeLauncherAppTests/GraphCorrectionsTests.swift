import Testing
import Foundation
@testable import BeLauncher
@testable import BeLauncherCore

/// Que corregir sirva de algo.
///
/// El grafo escribía las correcciones en el front matter y el motor las leía de otro sitio, así
/// que la pareja rechazada volvía a proponerse, lo marcado como importante seguía pesando igual y
/// lo olvidado reaparecía en la pasada siguiente. Estas pruebas recorren el camino entero: se
/// corrige en el grafo, se tira el modelo como si la app se hubiera cerrado, y se le pregunta al
/// motor qué va a hacer la próxima vez.
@Suite("Las correcciones del grafo vuelven al motor")
@MainActor
struct GraphCorrectionsTests {

    private let noon = Date(timeIntervalSince1970: 1_785_240_000)

    private func temporaryRoot() -> String {
        NSTemporaryDirectory() + "belauncher-graph-" + UUID().uuidString
    }

    private func makeStore(in root: String) throws -> Store {
        let store = try Store(path: (root as NSString).appendingPathComponent("s.sqlite3"))
        try store.migrateSemanticIndex()
        return store
    }

    /// Un motor recién arrancado, que solo sabe lo que hay en disco.
    private func engine(store: Store, corpusRoot: String) async -> CorpusRunner {
        let runner = CorpusRunner(store: store, brain: nil) { _, _ in "" }
        await runner.refreshCorrections(root: corpusRoot)
        return runner
    }

    private func input(_ runner: CorpusRunner, now: Date) -> CorpusBuilder.Input {
        runner.assemblyInput(now: now, visits: [], exchanges: [], transcripts: [])
    }

    private func episode(in model: GraphModel) -> String? {
        model.drawing.nodes.first { $0.shape == .episode }?.id
    }

    private func files(_ names: [String], in store: Store, from start: Date) {
        for (offset, name) in names.enumerated() {
            store.upsertNode(WorkNode(id: WorkNode.identifier(kind: .file, name: name),
                                      kind: .file, name: name, target: "/tmp/" + name,
                                      lastSeen: start.addingTimeInterval(Double(offset) * 300)))
        }
    }

    // MARK: - Fusiones

    @Test("Un «no son lo mismo» sobrevive al reinicio y el motor deja de preguntar")
    func rejectionSurvivesRestart() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try makeStore(in: root)
        let corpusRoot = (root as NSString).appendingPathComponent("corpus")

        let mine = WorkNode(id: WorkNode.identifier(kind: .project, name: "waw-trips"),
                            kind: .project, name: "waw-trips", lastSeen: noon, weight: 6)
        let theirs = WorkNode(id: WorkNode.identifier(kind: .project, name: "WAW Trips"),
                              kind: .project, name: "WAW Trips", lastSeen: noon, weight: 4)
        store.upsertNode(mine)
        store.upsertNode(theirs)

        let model = GraphModel(store: store, corpus: try CorpusFolder(root: corpusRoot), now: noon)
        model.selected = mine.id
        model.compared = theirs.id
        model.askAboutPair()
        let asked = try #require(model.proposal)
        model.rejectMerge()

        // Se cierra la app: nadie recuerda la pregunta salvo la carpeta.
        let runner = await engine(store: store, corpusRoot: corpusRoot)
        #expect(input(runner, now: noon).rejectedMerges.contains(asked.id))
    }

    @Test("Separar un alias también le llega al motor")
    func separatingReachesTheEngine() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try makeStore(in: root)
        let corpusRoot = (root as NSString).appendingPathComponent("corpus")

        let folded = WorkNode(id: WorkNode.identifier(kind: .project, name: "Acme"),
                              kind: .project, name: "Acme", lastSeen: noon, weight: 9)
        store.upsertNode(folded)

        let model = GraphModel(store: store, corpus: try CorpusFolder(root: corpusRoot), now: noon)
        model.selected = folded.id
        model.separate(alias: "Acme Studio")

        let undo = MergeProposal(left: "Acme", right: "Acme Studio", reason: .sameName)
        let runner = await engine(store: store, corpusRoot: corpusRoot)
        #expect(input(runner, now: noon).rejectedMerges.contains(undo.id))
    }

    // MARK: - Marcar importante

    @Test("Marcar algo importante en el grafo cambia lo que pesa en la búsqueda")
    func markReachesRelevance() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try makeStore(in: root)
        let corpusRoot = (root as NSString).appendingPathComponent("corpus")

        let node = WorkNode(id: WorkNode.identifier(kind: .file, name: "contrato.pdf"),
                            kind: .file, name: "contrato.pdf",
                            target: "/Users/mac/Documents/contrato.pdf", lastSeen: noon)
        store.upsertNode(node)

        let model = GraphModel(store: store, corpus: try CorpusFolder(root: corpusRoot), now: noon)
        model.selected = node.id
        model.markImportant(true)

        let marked = input(await engine(store: store, corpusRoot: corpusRoot), now: noon).markedByHand
        // El motor compara contra el sujeto de la señal, que es el destino cuando lo hay.
        #expect(marked.contains(node.target))
        #expect(marked.contains(node.id))
    }

    @Test("Un episodio marcado a mano le gana a cualquier señal automática")
    func markedEpisodeWinsEverything() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try makeStore(in: root)
        let corpusRoot = (root as NSString).appendingPathComponent("corpus")
        // Nada que empiece por `auth.` o `login.`: la lista de exclusiones de fábrica los tira, y
        // un fixture con esos nombres mide la privacidad en vez de lo que dice medir.
        files(["sesion.swift", "token.swift", "cookies.swift"], in: store, from: noon)

        let later = noon.addingTimeInterval(7_200)
        let model = GraphModel(store: store, corpus: try CorpusFolder(root: corpusRoot), now: later)
        await model.waitForLayout()
        model.selected = try #require(episode(in: model))
        model.markImportant(true)

        let runner = await engine(store: store, corpusRoot: corpusRoot)
        let assembled = CorpusBuilder.assemble(input(runner, now: later))
        let considered = try #require(assembled.considered.first)
        #expect(considered.signals.markedByHand)
        #expect(considered.score == 1)
    }

    // MARK: - Olvidar

    @Test("Olvidar un episodio desde el grafo borra lo que lo generó")
    func forgettingRemovesTheOriginal() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try makeStore(in: root)
        let corpusRoot = (root as NSString).appendingPathComponent("corpus")
        files(["nomina.numbers", "banco.pdf", "irpf.pdf"], in: store, from: noon)

        let later = noon.addingTimeInterval(7_200)
        let model = GraphModel(store: store, corpus: try CorpusFolder(root: corpusRoot), now: later)
        await model.waitForLayout()
        let id = try #require(episode(in: model))
        let forgotten = try #require(model.episode(id))
        model.selected = id
        model.forget()

        // Lo que lo generaba eran las señales de ese tramo, no la fila del episodio.
        #expect(store.isForgotten(forgotten.start))
        #expect(!store.nodes(limit: 100).contains { $0.name == "nomina.numbers" })

        // Y la siguiente pasada no lo reconstruye, aunque las fuentes se relean enteras: los
        // identificadores salen del contenido, así que sin esto la reconstrucción era exacta.
        let runner = await engine(store: store, corpusRoot: corpusRoot)
        var next = input(runner, now: later)
        next.nodes = ["nomina.numbers", "banco.pdf"].enumerated().map { offset, name in
            WorkNode(id: WorkNode.identifier(kind: .file, name: name), kind: .file, name: name,
                     target: "/tmp/" + name, lastSeen: noon.addingTimeInterval(Double(offset) * 300))
        }
        #expect(CorpusBuilder.assemble(next).episodes.isEmpty)
    }

    @Test("Lo que echas del grafo no vuelve como entidad en la pasada siguiente")
    func hiddenEntityIsNotUpsertedAgain() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try makeStore(in: root)
        let corpusRoot = (root as NSString).appendingPathComponent("corpus")

        // El id que le pone la pasada a una entidad, que es con el que la vuelve a escribir.
        let unwanted = WorkNode(id: Entity(kind: .person, canonical: "Alguien").id,
                                kind: .person, name: "Alguien", lastSeen: noon, weight: 4)
        store.upsertNode(unwanted)

        let model = GraphModel(store: store, corpus: try CorpusFolder(root: corpusRoot), now: noon)
        model.selected = unwanted.id
        model.forget()

        // La pasada siguiente vuelve a deducir la misma entidad y la escribe como nodo. Sin esto,
        // borrarla del grafo duraba media hora.
        let runner = await engine(store: store, corpusRoot: corpusRoot)
        await runner.write(Corpus(entities: [Entity(id: unwanted.id, kind: .person,
                                              canonical: "Alguien", weight: 5)]))
        #expect(!store.nodes(limit: 100).contains { $0.id == unwanted.id })
    }

    // MARK: - La ventana

    @Test("Filtrar no congela la ventana")
    func filteringDoesNotBlockTheWindow() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try makeStore(in: root)

        // Trescientos nodos es el presupuesto del lienzo: el peor caso que llega a dibujarse.
        for offset in 0..<300 {
            store.upsertNode(WorkNode(id: "project:p\(offset)", kind: .project, name: "p\(offset)",
                                      lastSeen: noon.addingTimeInterval(Double(offset) * 60)))
        }

        let model = GraphModel(store: store, corpus: nil, now: noon.addingTimeInterval(86_400))
        await model.waitForLayout()

        // Medido antes: medio segundo de hilo principal por cada tecla del filtro. El margen es
        // enorme a propósito: lo que se afirma es que el cálculo ya no está aquí, no cuánto tarda
        // una máquina cargada en hacerlo.
        let started = DispatchTime.now().uptimeNanoseconds
        model.query = "p1"
        let blocked = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        #expect(blocked < 100)

        await model.waitForLayout()
        #expect(!model.drawing.isEmpty)
    }

    @Test("Escribir seguido dibuja una vez, no una por letra")
    func typingDrawsOnce() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try makeStore(in: root)
        for offset in 0..<40 {
            store.upsertNode(WorkNode(id: "project:waw\(offset)", kind: .project,
                                      name: "waw\(offset)", lastSeen: noon))
        }

        let model = GraphModel(store: store, corpus: nil, now: noon.addingTimeInterval(86_400))
        await model.waitForLayout()
        let before = model.layouts

        for letter in ["w", "wa", "waw", "waw1"] { model.query = letter }
        await model.waitForLayout()

        #expect(model.layouts - before == 1)
        #expect(model.drawing.nodes.allSatisfy { $0.label.hasPrefix("waw1") })
    }
}
