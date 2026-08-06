import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Armar episodios")
struct EpisodeTests {

    /// Un mediodía fijo. Las pruebas que usan la hora del sistema fallan de madrugada y pasan por
    /// la tarde, que es el peor rojo posible: enseña a reintentar en vez de a mirar.
    private let noon = Date(timeIntervalSince1970: 1_785_240_000)

    private func signal(_ minutes: Double, _ subject: String,
                        kind: Episode.Signal.Kind = .file) -> Episode.Signal {
        Episode.Signal(at: noon.addingTimeInterval(minutes * 60), kind: kind,
                       subject: subject, title: subject)
    }

    @Test("Lo que ocurre seguido es un solo recuerdo, no una fila por evento")
    func oneEpisode() {
        let episodes = EpisodeBuilder.episodes(
            from: [signal(0, "auth.swift"), signal(5, "login.swift"), signal(20, "auth.swift")])
        #expect(episodes.count == 1)
        #expect(episodes[0].signals.count == 3)
    }

    @Test("Una pausa larga separa dos recuerdos")
    func idleSplits() {
        let episodes = EpisodeBuilder.episodes(
            from: [signal(0, "auth.swift"), signal(3, "auth.swift"),
                   signal(90, "factura.pdf"), signal(95, "factura.pdf")])
        #expect(episodes.count == 2)
    }

    @Test("Una pausa corta no parte el trabajo en trozos")
    func shortPauseKeepsOne() {
        // Un café de quince minutos no es cambiar de tarea. Cortar aquí produciría cuatro
        // episodios sobre lo mismo, que es peor que uno con un hueco.
        let episodes = EpisodeBuilder.episodes(
            from: [signal(0, "auth.swift"), signal(15, "auth.swift"), signal(30, "auth.swift")])
        #expect(episodes.count == 1)
    }

    @Test("Un solo evento suelto no es un recuerdo")
    func loneSignal() {
        #expect(EpisodeBuilder.episodes(from: [signal(0, "algo")]).isEmpty)
    }

    @Test("Cambiar de app no es trabajar: no genera recuerdos por sí solo")
    func appSwitchingIsNotWork() {
        let switching = (0..<6).map { signal(Double($0) * 2, "Safari", kind: .application) }
        #expect(EpisodeBuilder.episodes(from: switching).isEmpty)
    }

    @Test("Pero una app junto a trabajo de verdad sí cuenta como parte del recuerdo")
    func appAlongsideWork() {
        let episodes = EpisodeBuilder.episodes(
            from: [signal(0, "Safari", kind: .application), signal(4, "auth.swift")])
        #expect(episodes.count == 1)
        #expect(episodes[0].signals.count == 2)
    }

    @Test("Algo de dos segundos no es un recuerdo")
    func tooShort() {
        let quick = [signal(0, "a.txt"), Episode.Signal(at: noon.addingTimeInterval(3), kind: .file,
                                                        subject: "b.txt", title: "b.txt")]
        #expect(EpisodeBuilder.episodes(from: quick).isEmpty)
    }

    @Test("Un día entero seguido no es un recuerdo: se parte")
    func marathonSplits() {
        // Señales cada diez minutos durante nueve horas, sin ninguna pausa larga.
        let long = (0..<54).map { signal(Double($0) * 10, "monolito.swift") }
        let episodes = EpisodeBuilder.episodes(from: long)
        #expect(episodes.count >= 2)
        #expect(episodes.allSatisfy { $0.duration <= EpisodeBuilder.maximumLength + 1 })
    }

    @Test("Las señales desordenadas se ordenan solas")
    func unordered() {
        let episodes = EpisodeBuilder.episodes(
            from: [signal(20, "c"), signal(0, "a"), signal(10, "b")])
        #expect(episodes.count == 1)
        #expect(episodes[0].start == noon)
    }

    @Test("El mismo día armado dos veces da los mismos identificadores, no copias")
    func stableIdentity() {
        // El armado corre una y otra vez según llegan señales. Sin identificador estable, el
        // índice se llenaría de duplicados del mismo recuerdo.
        let input = [signal(0, "auth.swift"), signal(6, "login.swift")]
        let first = EpisodeBuilder.episodes(from: input)
        let second = EpisodeBuilder.episodes(from: input)
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("Dos recuerdos distintos no comparten identificador")
    func distinctIdentity() {
        let episodes = EpisodeBuilder.episodes(
            from: [signal(0, "auth.swift"), signal(5, "auth.swift"),
                   signal(120, "factura.pdf"), signal(126, "factura.pdf")])
        #expect(Set(episodes.map(\.id)).count == episodes.count)
    }

    @Test("Lo que se tocó más manda en la lista de asuntos")
    func subjectsRanked() {
        let episodes = EpisodeBuilder.episodes(
            from: [signal(0, "auth.swift"), signal(4, "otro.swift"), signal(8, "auth.swift")])
        #expect(episodes[0].subjects.first == "auth.swift")
    }

    @Test("El título provisional nombra lo que se tocó y no inventa un significado")
    func fallbackTitle() {
        let episodes = EpisodeBuilder.episodes(
            from: [signal(0, "auth.swift"), signal(5, "login.swift")])
        let title = episodes[0].title
        #expect(title.contains("auth.swift"))
        #expect(title.contains("login.swift"))
    }

    @Test("El título provisional no repite lo mismo cuatro veces")
    func titleDeduplicates() {
        let episodes = EpisodeBuilder.episodes(
            from: [signal(0, "auth.swift"), signal(3, "auth.swift"), signal(6, "auth.swift")])
        #expect(episodes[0].title == "auth.swift")
    }

    @Test("Un recuerdo que aún está pasando no se da por cerrado")
    func unsettled() {
        let episodes = EpisodeBuilder.episodes(
            from: [signal(0, "auth.swift"), signal(5, "auth.swift")])
        let justEnded = noon.addingTimeInterval(6 * 60)
        #expect(EpisodeBuilder.isSettled(episodes[0], now: justEnded) == false)
        #expect(EpisodeBuilder.isSettled(episodes[0], now: noon.addingTimeInterval(60 * 60)))
    }

    @Test("Sin señales no hay recuerdos y no revienta")
    func empty() {
        #expect(EpisodeBuilder.episodes(from: []).isEmpty)
    }
}
