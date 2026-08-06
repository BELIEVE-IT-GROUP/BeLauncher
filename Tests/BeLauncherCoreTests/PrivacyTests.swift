import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Poder decirle que pare")
struct PrivacyTests {

    private let noon = Date(timeIntervalSince1970: 1_785_240_000)

    @Test("En pausa a mano no se guarda nada, hasta que se reanude")
    func pausedByHand() {
        let state = Privacy.State(reason: .byHand)
        #expect(!state.isCapturing(at: noon))
        #expect(!state.isCapturing(at: noon.addingTimeInterval(86_400)))
    }

    @Test("La pausa temporal se levanta sola")
    func pausedUntil() {
        let state = Privacy.State(reason: .untilLater, until: noon.addingTimeInterval(1800))
        #expect(!state.isCapturing(at: noon))
        #expect(state.isCapturing(at: noon.addingTimeInterval(1801)))
    }

    @Test("Una pausa se ve como pausa, no como funcionamiento normal")
    func pauseIsVisible() {
        let text = Privacy.State(reason: .byHand).summary(at: noon)
        #expect(text.contains("Nothing is being kept"))
        #expect(Privacy.State().summary(at: noon).contains("Capturing"))
    }

    @Test("Dice cuánto queda de una pausa temporal")
    func pauseCountsDown() {
        let state = Privacy.State(reason: .untilLater, until: noon.addingTimeInterval(600))
        #expect(state.summary(at: noon).contains("10 min"))
    }

    @Test("Los gestores de contraseñas están excluidos de fábrica, no en blanco")
    func defaultExclusions() {
        // Una lista vacía significa que la primera ventana del gestor entra antes de que a nadie
        // se le ocurra configurar nada, y entonces ya es tarde.
        #expect(Privacy.excludedByDefault.contains("com.1password.1password"))
        #expect(Privacy.isExcluded(bundleIdentifier: "com.1password.1password", url: nil,
                                   apps: Set(Privacy.excludedByDefault), domains: []))
    }

    @Test("Un banco se reconoce aunque cambie de subdominio")
    func domainExclusion() {
        #expect(Privacy.isExcluded(bundleIdentifier: nil,
                                   url: "https://empresas.bbva.es/cuentas",
                                   apps: [], domains: Set(Privacy.excludedDomainsByDefault)))
    }

    @Test("Lo que no está excluido pasa")
    func normalPasses() {
        #expect(!Privacy.isExcluded(bundleIdentifier: "com.apple.Safari",
                                    url: "https://github.com/acme/infra",
                                    apps: Set(Privacy.excludedByDefault),
                                    domains: Set(Privacy.excludedDomainsByDefault)))
    }

    @Test("Un periodo al revés se entiende igual")
    func reversedPeriod() {
        let period = Privacy.Period(from: noon, to: noon.addingTimeInterval(-3600))
        #expect(period.from < period.to)
        #expect(period.contains(noon.addingTimeInterval(-1800)))
    }
}

@Suite("Olvidar un rato")
@MainActor
struct ForgettingTests {

    private func makeStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-privacy-\(UUID().uuidString)")
            .appendingPathComponent("s.sqlite3").path
        let store = try Store(path: path)
        try store.migrateSemanticIndex()
        return store
    }

    @Test("Se dice cuánto se va a borrar antes de borrarlo")
    func countsBeforeDeleting() throws {
        let store = try makeStore()
        let when = Date(timeIntervalSince1970: 1_785_240_000)
        _ = store.replacePassages(for: IndexedSource(kind: .note, id: "n1"), title: "T",
                                  occurredAt: when,
                                  text: "Una nota con longitud suficiente para convertirse en pasaje.")

        let period = Privacy.Period(from: when.addingTimeInterval(-60), to: when.addingTimeInterval(60))
        let preview = store.whatWouldBeForgotten(period)
        #expect(preview.passages == 1)
        #expect(preview.warning.contains("for good"))
        // Y contar no borra.
        #expect(store.indexedPassageCount().total == 1)
    }

    @Test("Olvidar quita también el pasaje indexado, no solo el original")
    func forgettingRemovesTheIndex() throws {
        // Borrar el clip y dejar su pasaje vectorizado significa que la cosa sigue contestando
        // preguntas después de haber sido olvidada. Peor que no haber ofrecido olvidarla.
        let store = try makeStore()
        let when = Date(timeIntervalSince1970: 1_785_240_000)
        _ = store.replacePassages(for: IndexedSource(kind: .clip, id: "c1"), title: "T",
                                  occurredAt: when,
                                  text: "Algo copiado que no debería sobrevivir al olvido.")
        #expect(!store.matchingWords("copiado").isEmpty)

        store.forget(Privacy.Period(from: when.addingTimeInterval(-60), to: when.addingTimeInterval(60)))
        #expect(store.matchingWords("copiado").isEmpty)
        #expect(store.indexedPassageCount().total == 0)
    }

    @Test("Olvidar un rato no toca lo de fuera de ese rato")
    func forgettingIsSurgical() throws {
        let store = try makeStore()
        let when = Date(timeIntervalSince1970: 1_785_240_000)
        _ = store.replacePassages(for: IndexedSource(kind: .note, id: "dentro"), title: "T",
                                  occurredAt: when, text: "Esto estaba dentro del rato olvidado.")
        _ = store.replacePassages(for: IndexedSource(kind: .note, id: "fuera"), title: "T",
                                  occurredAt: when.addingTimeInterval(86_400),
                                  text: "Esto pasó al día siguiente y tiene que sobrevivir.")

        store.forget(Privacy.Period(from: when.addingTimeInterval(-60), to: when.addingTimeInterval(60)))
        #expect(store.matchingWords("dentro").isEmpty)
        #expect(!store.matchingWords("siguiente").isEmpty)
    }

    @Test("La pausa se recuerda entre arranques")
    func pausePersists() throws {
        let store = try makeStore()
        store.pauseCapture(.byHand)
        #expect(!store.privacyState.isCapturing())
        store.pauseCapture(.notPaused)
        #expect(store.privacyState.isCapturing())
    }
}

@Suite("Conversaciones con un asistente")
struct ConversationTests {

    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @Test("De una pregunta y su respuesta sale un intercambio")
    func basicExchange() {
        let lines = [
            line(["type": "user", "cwd": "/Users/mac/Developer/waw-trips",
                  "message": ["content": "cómo resolví el problema de autenticación de la semana pasada"]]),
            line(["type": "assistant", "cwd": "/Users/mac/Developer/waw-trips",
                  "message": ["content": [["type": "text", "text": "Con un token de refresco."]]]]),
        ]
        let exchanges = Conversations.exchanges(inLines: lines)
        #expect(exchanges.count == 1)
        #expect(exchanges[0].asked.contains("autenticación"))
        #expect(exchanges[0].answered.contains("refresco"))
    }

    @Test("El razonamiento interno del modelo no se indexa")
    func thinkingIsDropped() {
        // Es largo y es la máquina hablando consigo misma: buscar tus propias palabras
        // devolvería eso.
        let lines = [
            line(["type": "user", "message": ["content": "una pregunta lo bastante larga para contar"]]),
            line(["type": "assistant",
                  "message": ["content": [["type": "thinking", "thinking": "déjame pensar"],
                                          ["type": "text", "text": "La respuesta."]]]]),
        ]
        let exchanges = Conversations.exchanges(inLines: lines)
        #expect(exchanges[0].answered == "La respuesta.")
    }

    @Test("Los resultados de herramienta no son algo que dijera una persona")
    func toolResultsIgnored() {
        let lines = [
            line(["type": "user",
                  "message": ["content": [["type": "tool_result", "content": "build succeeded en 4s con todo"]]]]),
            line(["type": "assistant", "message": ["content": [["type": "text", "text": "Listo."]]]]),
        ]
        #expect(Conversations.exchanges(inLines: lines).isEmpty)
    }

    @Test("«sí» y «sigue» no son preguntas que nadie vaya a buscar")
    func shortAnswersIgnored() {
        let lines = [
            line(["type": "user", "message": ["content": "sí"]]),
            line(["type": "assistant", "message": ["content": [["type": "text", "text": "Vale."]]]]),
        ]
        #expect(Conversations.exchanges(inLines: lines).isEmpty)
    }

    @Test("Una línea rota no se lleva por delante el resto del día")
    func brokenLineSurvives() {
        let lines = [
            "{ esto no es json",
            line(["type": "user", "message": ["content": "una pregunta con longitud más que suficiente"]]),
            line(["type": "assistant", "message": ["content": [["type": "text", "text": "Respuesta."]]]]),
        ]
        #expect(Conversations.exchanges(inLines: lines).count == 1)
    }

    @Test("Las conversaciones de subagentes no entran")
    func sidechainsIgnored() {
        let lines = [
            line(["type": "user", "isSidechain": true,
                  "message": ["content": "una pregunta con longitud más que suficiente"]]),
            line(["type": "assistant", "isSidechain": true,
                  "message": ["content": [["type": "text", "text": "Respuesta."]]]]),
        ]
        #expect(Conversations.exchanges(inLines: lines).isEmpty)
    }

    @Test("La pregunta va delante, porque es lo que se busca meses después")
    func questionLeads() {
        let exchange = Conversations.Exchange(
            at: Date(timeIntervalSince1970: 1_785_240_000),
            asked: "cómo resolví lo de autenticación",
            answered: "con un token de refresco",
            workingDirectory: "/Users/mac/Developer/waw-trips")
        let item = Conversations.items(from: [exchange])[0]
        #expect(item.text.hasPrefix("cómo resolví"))
        #expect(item.text.contains("waw-trips"))
        #expect(item.source.kind == .conversation)
    }
}

@Suite("Lo olvidado no vuelve")
@MainActor
struct ForgottenStaysForgottenTests {

    private let noon = Date(timeIntervalSince1970: 1_785_240_000)

    private func makeStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-forgotten-\(UUID().uuidString)")
            .appendingPathComponent("s.sqlite3").path
        let store = try Store(path: path)
        try store.migrateSemanticIndex()
        return store
    }

    @Test("Olvidar un rato se anota, y se anota para siempre")
    func ledgerPersists() throws {
        let store = try makeStore()
        store.forget(Privacy.Period(from: noon.addingTimeInterval(-3600), to: noon))
        #expect(store.isForgotten(noon.addingTimeInterval(-1800)))
        #expect(!store.isForgotten(noon.addingTimeInterval(3600)))
    }

    @Test("Volver a ensamblar el corpus no resucita lo olvidado")
    func reassemblyDoesNotResurrect() {
        // Este es el fallo que midió la auditoría: las fuentes se releen en cada pasada y los
        // identificadores salen del contenido, así que la reconstrucción era exacta. «Para
        // siempre» duraba hasta la siguiente indexación, media hora.
        let exchange = Conversations.Exchange(
            at: noon, asked: "una conversación con longitud más que suficiente para indexarse",
            answered: "la respuesta", workingDirectory: "/Users/mac/Developer/waw-trips")

        let sinOlvido = CorpusBuilder.assemble(CorpusBuilder.Input(exchanges: [exchange], now: noon.addingTimeInterval(7200)))
        #expect(!sinOlvido.items.isEmpty)

        let conOlvido = CorpusBuilder.assemble(CorpusBuilder.Input(
            exchanges: [exchange],
            forgotten: [Privacy.Period(from: noon.addingTimeInterval(-600), to: noon.addingTimeInterval(600))],
            now: noon.addingTimeInterval(7200)))
        #expect(conOlvido.items.isEmpty)
    }
}
