import Testing
import Foundation
@testable import BeLauncher
@testable import BeLauncherCore

/// La pasada que de verdad corre.
///
/// `CorpusBuilder` tiene puertas para las dos promesas que más pesan — la pausa y los ratos que
/// alguien pidió olvidar — y estaba probado a fondo. Lo que no estaba probado era quien lo llama, y
/// ahí es donde una de las dos puertas se quedaba sin llave: el runner nunca le pasaba los periodos
/// olvidados, así que el registro que escribe `Store.forget` no lo leía nadie.
@Suite("La pasada del corpus")
@MainActor
struct CorpusRunnerTests {

    private func temporaryStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-runner-test-\(UUID().uuidString)")
            .appendingPathComponent("test.sqlite3").path
        return try Store(path: path)
    }

    /// Un runner sin cerebro ni modelo: nada de lo que se prueba aquí los necesita, y pedirlos
    /// convertiría estas pruebas en pruebas de red.
    private func runner(_ store: Store) -> CorpusRunner {
        CorpusRunner(store: store, brain: nil, ask: { _, _ in
            Issue.record("no se debería haber llamado al modelo")
            return ""
        })
    }

    private var morning: Date { Date(timeIntervalSince1970: 1_785_240_000) }

    /// Un rato de navegación con forma de episodio: tres señales con título, repartidas en veinte
    /// minutos, que es más de los noventa segundos y las dos señales que pide `EpisodeBuilder`.
    private func browsing(from start: Date, about topic: String) -> [BrowserVisit] {
        (0..<3).map { step in
            BrowserVisit(at: start.addingTimeInterval(Double(step) * 600),
                         url: "https://ejemplo.com/\(topic)/\(step)",
                         title: "\(topic) paso \(step)", browser: "Safari")
        }
    }

    // MARK: - La pausa

    @Test("con la captura apagada no se captura, aunque la privacidad esté limpia")
    func laCapturaApagadaManda() throws {
        let store = try temporaryStore()
        #expect(!runner(store).isCapturing)

        store.setSetting("graph_enabled", true)
        #expect(runner(store).isCapturing)
    }

    @Test("una pausa apaga la captura aunque el grafo esté encendido")
    func laPausaApagaLaCaptura() throws {
        let store = try temporaryStore()
        store.setSetting("graph_enabled", true)

        store.pauseCapture(.byHand)
        #expect(!runner(store).isCapturing)

        store.pauseCapture(.untilLater, until: Date.now.addingTimeInterval(900))
        #expect(!runner(store).isCapturing)

        // Una pausa temporal vencida deja volver sola, sin que nadie toque nada.
        store.pauseCapture(.untilLater, until: Date.now.addingTimeInterval(-1))
        #expect(runner(store).isCapturing)

        store.pauseCapture(.notPaused)
        #expect(runner(store).isCapturing)
    }

    @Test("una pasada con la captura apagada no deja rastro de haber corrido")
    func laPasadaApagadaNoEscribeNada() async throws {
        // Nadie ha dicho que sí al grafo. Esta es la única puerta que corta aquí: la privacidad
        // está limpia, así que el ensamblado no se declararía en pausa si la pasada llegara a él.
        let cerrado = try temporaryStore()
        await runner(cerrado).runOnce(now: morning)
        #expect(cerrado.setting("corpus_last_run") == nil)
        #expect(cerrado.setting("corpus_last_passages") == nil)

        // Y con el grafo encendido pero la captura en pausa, lo mismo: ni la marca de la última
        // pasada ni la cuenta de pasajes. Una captura en pausa no toca el disco, ni para decir
        // que estuvo aquí.
        let enPausa = try temporaryStore()
        enPausa.setSetting("graph_enabled", true)
        enPausa.pauseCapture(.byHand)
        await runner(enPausa).runOnce(now: morning)
        #expect(enPausa.setting("corpus_last_run") == nil)
        #expect(enPausa.setting("corpus_last_passages") == nil)
    }

    @Test("la pausa corta el ensamblado aunque haya material recogido")
    func laPausaCortaElEnsamblado() throws {
        let store = try temporaryStore()
        store.setSetting("graph_enabled", true)
        store.pauseCapture(.byHand)

        let input = runner(store).assemblyInput(
            now: morning.addingTimeInterval(10 * 3_600),
            visits: browsing(from: morning, about: "trabajo"), exchanges: [], transcripts: [])

        #expect(CorpusBuilder.assemble(input).isPaused)
    }

    // MARK: - Los ratos olvidados

    @Test("lo que se pidió olvidar no vuelve en la siguiente pasada")
    func loOlvidadoNoVuelve() throws {
        let store = try temporaryStore()
        store.setSetting("graph_enabled", true)

        // La tarde que se olvida. El historial del navegador vive en el archivo del navegador, no
        // en nuestra base: `forget` no lo toca y la siguiente pasada lo vuelve a leer entero, con
        // sus fechas originales. Sin la puerta, olvidar duraba media hora.
        let afternoon = Privacy.Period(from: morning, to: morning.addingTimeInterval(3 * 3_600))
        store.forget(afternoon)

        let input = runner(store).assemblyInput(
            now: morning.addingTimeInterval(10 * 3_600),
            visits: browsing(from: morning.addingTimeInterval(600), about: "la-tarde-olvidada"),
            exchanges: [], transcripts: [])
        let corpus = CorpusBuilder.assemble(input)

        #expect(!corpus.isPaused)
        #expect(corpus.episodes.isEmpty)
        #expect(corpus.items.isEmpty)
    }

    @Test("olvidar una tarde no borra la mañana")
    func olvidarUnaTardeNoBorraLaManana() throws {
        let store = try temporaryStore()
        store.setSetting("graph_enabled", true)

        let afternoon = Privacy.Period(from: morning.addingTimeInterval(6 * 3_600),
                                       to: morning.addingTimeInterval(10 * 3_600))
        store.forget(afternoon)

        let input = runner(store).assemblyInput(
            now: morning.addingTimeInterval(20 * 3_600),
            visits: browsing(from: morning, about: "sigue-aqui")
                  + browsing(from: morning.addingTimeInterval(7 * 3_600), about: "ya-no-esta"),
            exchanges: [], transcripts: [])
        let corpus = CorpusBuilder.assemble(input)

        #expect(corpus.episodes.count == 1)
        #expect(!corpus.items.contains { $0.text.contains("ya-no-esta") })
        #expect(corpus.items.contains { $0.text.contains("sigue-aqui") })
    }

    @Test("sin nada olvidado el material entra igual que siempre")
    func sinOlvidosEntraTodo() throws {
        let store = try temporaryStore()
        store.setSetting("graph_enabled", true)

        let input = runner(store).assemblyInput(
            now: morning.addingTimeInterval(10 * 3_600),
            visits: browsing(from: morning, about: "trabajo"), exchanges: [], transcripts: [])
        let corpus = CorpusBuilder.assemble(input)

        // Si esto se pusiera vacío, las dos pruebas de arriba pasarían sin probar nada.
        #expect(input.forgotten.isEmpty)
        #expect(corpus.episodes.count == 1)
    }

    // MARK: - Las exclusiones llegan hasta el ensamblado

    @Test("el runner le pasa al ensamblado la lista de exclusiones del usuario, no una vacía")
    func lasExclusionesLleganAlEnsamblado() throws {
        let store = try temporaryStore()
        store.setSetting("graph_enabled", true)
        store.setExcludedDomains(["terapia-privada.com"])

        let input = runner(store).assemblyInput(
            now: morning.addingTimeInterval(10 * 3_600),
            visits: [BrowserVisit(at: morning, url: "https://terapia-privada.com/cita",
                                  title: "Mi cita", browser: "Safari")],
            exchanges: [], transcripts: [])

        #expect(input.excludedDomains == ["terapia-privada.com"])
        #expect(!CorpusBuilder.assemble(input).items.contains { $0.text.contains("Mi cita") })
    }

    @Test("una base recién creada llega al ensamblado con las exclusiones de fábrica puestas")
    func lasExclusionesDeFabricaLlegan() throws {
        let store = try temporaryStore()
        store.setSetting("graph_enabled", true)

        let input = runner(store).assemblyInput(now: morning, visits: [], exchanges: [],
                                                transcripts: [])

        #expect(input.excludedApps == Set(Privacy.excludedByDefault))
        #expect(input.excludedDomains == Set(Privacy.excludedDomainsByDefault))
    }

    // MARK: - La ventana

    @Test("la pasada no recoge material más viejo que su ventana")
    func laVentanaRecorta() throws {
        let store = try temporaryStore()
        store.setSetting("graph_enabled", true)

        let now = morning.addingTimeInterval(10 * 3_600)
        store.upsertNode(WorkNode(id: "viejo", kind: .file, name: "viejo.ts",
                                  target: "/Users/mac/viejo.ts",
                                  lastSeen: now.addingTimeInterval(-CorpusRunner.window - 60)))
        store.upsertNode(WorkNode(id: "reciente", kind: .file, name: "reciente.ts",
                                  target: "/Users/mac/reciente.ts",
                                  lastSeen: now.addingTimeInterval(-600)))

        let input = runner(store).assemblyInput(now: now, visits: [], exchanges: [],
                                                transcripts: [])

        #expect(input.nodes.map(\.id) == ["reciente"])
    }
}
