import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Qué merece recordarse")
struct RelevanceTests {

    @Test("Pasar tres segundos por algo no lo mete en el buscador")
    func glance() {
        #expect(!Relevance.isWorthIndexing(Relevance.Signals(dwell: 3)))
    }

    @Test("Volver otro día es la señal más fuerte")
    func returning() {
        // Nadie reabre algo por error una semana después.
        #expect(Relevance.isWorthIndexing(Relevance.Signals(dwell: 10, daysSeen: 2)))
    }

    @Test("Copiar algo de ahí dice que sirvió")
    func copying() {
        let copied = Relevance.score(Relevance.Signals(dwell: 30, copiedFrom: true))
        let not = Relevance.score(Relevance.Signals(dwell: 30, copiedFrom: false))
        #expect(copied > not)
    }

    @Test("Dejar una ventana abierta toda la tarde no gana a diez minutos de foco")
    func dwellSaturates() {
        // Sin techo, comer con el editor abierto sería lo más importante del día.
        let afternoon = Relevance.score(Relevance.Signals(dwell: 4 * 3600))
        let focused = Relevance.score(Relevance.Signals(dwell: 20 * 60))
        #expect(afternoon == focused)
    }

    @Test("Guardarlo a mano gana a cualquier señal automática")
    func handBeatsEverything() {
        #expect(Relevance.score(Relevance.Signals(dwell: 0, markedByHand: true)) == 1)
    }

    @Test("La puntuación nunca se pasa de uno por acumular señales")
    func capped() {
        let everything = Relevance.Signals(dwell: 10 * 3600, daysSeen: 9, copiedFrom: true,
                                           neighbours: 40)
        #expect(Relevance.score(everything) <= 1)
    }

    @Test("Estar acompañado ayuda, pero no decide solo")
    func neighboursHelp() {
        let alone = Relevance.score(Relevance.Signals(dwell: 120))
        let accompanied = Relevance.score(Relevance.Signals(dwell: 120, neighbours: 3))
        #expect(accompanied > alone)
        #expect(!Relevance.isWorthIndexing(Relevance.Signals(neighbours: 3)))
    }

    @Test("Se explica por qué entró, en palabras que se pueden usar")
    func explains() {
        let text = Relevance.explain(Relevance.Signals(dwell: 600, daysSeen: 3, copiedFrom: true))
        #expect(text.contains("3 different days"))
        #expect(text.contains("copied something"))
    }

    @Test("Y también por qué no entró")
    func explainsRejection() {
        let text = Relevance.explain(Relevance.Signals(dwell: 4))
        #expect(text.contains("did not make it"))
    }

    @Test("Las señales de un episodio salen de lo que pasó, sin leer su contenido")
    func fromEpisode() {
        let start = Date(timeIntervalSince1970: 1_785_240_000)
        let episode = Episode(
            id: "e", start: start, end: start.addingTimeInterval(900),
            signals: [Episode.Signal(at: start, kind: .file, subject: "a", title: "a"),
                      Episode.Signal(at: start, kind: .clip, subject: "b", title: "b")])
        let signals = Relevance.signals(for: episode)
        #expect(signals.dwell == 900)
        #expect(signals.copiedFrom)
    }
}

@Suite("Destilar el día en frases")
struct DistillationTests {

    private let day = Date(timeIntervalSince1970: 1_785_240_000)

    private func episode(_ id: String) -> Episode {
        Episode(id: id, start: day, end: day.addingTimeInterval(1800),
                signals: [Episode.Signal(at: day, kind: .file, subject: id, title: id)],
                title: id)
    }

    @Test("Una frase con su cita se conserva y apunta a su episodio")
    func keepsCited() {
        let statements = Distillation.parse(
            "Cerraste el problema de autenticación en waw-trips. [1]",
            episodes: [episode("e1")], day: day)
        #expect(statements.count == 1)
        #expect(statements[0].sources == ["e1"])
        #expect(!statements[0].text.contains("["))
    }

    @Test("Una frase sin cita se tira, no se muestra con una advertencia")
    func discardsUncited() {
        // Una frase que no se puede atribuir es indistinguible de una real y enseña que el
        // cerebro inventa. Peor que no tenerla.
        let statements = Distillation.parse(
            "Tuviste un día muy productivo.", episodes: [episode("e1")], day: day)
        #expect(statements.isEmpty)
    }

    @Test("Una cita que apunta a un episodio que no se envió invalida la frase entera")
    func discardsInventedCitation() {
        let statements = Distillation.parse(
            "Algo que suena bien. [9]", episodes: [episode("e1")], day: day)
        #expect(statements.isEmpty)
    }

    @Test("Si una de las citas es falsa, no se salva la frase por las buenas")
    func partiallyInvented() {
        let statements = Distillation.parse(
            "Trabajaste en dos cosas. [1][7]", episodes: [episode("e1")], day: day)
        #expect(statements.isEmpty)
    }

    @Test("Varias frases citando varios episodios")
    func several() {
        let statements = Distillation.parse("""
        - Cerraste la autenticación de waw-trips. [1]
        - Preparaste la propuesta para Acme. [2]
        """, episodes: [episode("e1"), episode("e2")], day: day)
        #expect(statements.count == 2)
        #expect(statements[1].sources == ["e2"])
        #expect(!statements[1].text.hasPrefix("-"))
    }

    @Test("Una respuesta vacía o de ruido no produce frases")
    func noise() {
        #expect(Distillation.parse("", episodes: [episode("e1")], day: day).isEmpty)
        #expect(Distillation.parse("ok [1]", episodes: [episode("e1")], day: day).isEmpty)
    }

    @Test("El prompt numera los episodios y exige citar")
    func promptCites() {
        let (system, user) = Distillation.prompt(for: [episode("e1"), episode("e2")])
        #expect(system.contains("[n]"))
        #expect(system.contains("Do not invent"))
        #expect(user.contains("[1]"))
        #expect(user.contains("[2]"))
    }

    @Test("Un episodio que aún está pasando no se destila")
    func onlySettled() {
        let live = Episode(id: "vivo", start: day, end: day.addingTimeInterval(600),
                           signals: [Episode.Signal(at: day, kind: .file, subject: "a", title: "a")])
        let ready = Distillation.ready([live], now: day.addingTimeInterval(660))
        #expect(ready.isEmpty)
    }

    @Test("El mismo texto y las mismas fuentes dan el mismo identificador")
    func stableIdentity() {
        let a = Distillation.Statement(text: "algo", sources: ["e1"], day: day)
        let b = Distillation.Statement(text: "algo", sources: ["e1"], day: day)
        #expect(a.id == b.id)
    }
}
