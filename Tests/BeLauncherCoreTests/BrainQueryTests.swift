import Testing
import Foundation
@testable import BeLauncherCore

@Suite("What did we decide, and prepare me")
struct BrainQueryTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func decision(_ statement: String, entities: [String] = ["pricing"],
                          owner: String = "Jorge", from: Double = -100,
                          until: Double? = nil, status: MemoryObject.Status = .active,
                          supersedes: [String] = []) -> MemoryObject {
        MemoryObject(level: .committed, kind: .decision, statement: statement,
                     source: "Reunión de producto", owner: owner,
                     createdAt: now.addingTimeInterval(from),
                     validFrom: now.addingTimeInterval(from),
                     validUntil: until.map { now.addingTimeInterval($0) },
                     status: status, supersedes: supersedes, entities: entities)
    }

    // MARK: - Intent

    @Test("the three questions are recognised, in both languages, and nothing else is")
    func intents() {
        #expect(BrainQuery.Intent.detect("qué decidimos sobre pricing")
                == .whatDidWeDecide(topic: "pricing"))
        #expect(BrainQuery.Intent.detect("What did we decide about pricing")
                == .whatDidWeDecide(topic: "pricing"))
        #expect(BrainQuery.Intent.detect("prepárame para Acme") == .prepare(subject: "Acme"))
        #expect(BrainQuery.Intent.detect("recordar esto que dijo el cliente")
                == .remember(text: "esto que dijo el cliente"))

        #expect(BrainQuery.Intent.detect("safari") == .none)
        #expect(BrainQuery.Intent.detect("2+2") == .none)
        #expect(BrainQuery.Intent.detect("qu") == .none)
    }

    // MARK: - What did we decide

    @Test("it answers with the decision in force, not with everything ever said")
    func currentDecision() {
        let old = decision("Precio enterprise 1500", from: -1000, until: -500, status: .superseded)
        let new = decision("Precio enterprise 2000", from: -400, supersedes: [old.id])
        let answer = BrainQuery.whatDidWeDecide(topic: "precio enterprise",
                                                in: [old, new], at: now)

        #expect(answer.body.contains("Precio enterprise 2000"))
        #expect(answer.body.contains("Sustituyó a:"), "what it replaced is the part nobody keeps")
        #expect(answer.body.contains("Precio enterprise 1500"))
        #expect(answer.body.contains("Jorge"))
        #expect(answer.citations.count == 2, "every claim carries its source")
        #expect(answer.gap == nil)
    }

    @Test("an interpretation never passes for a decision")
    func extractedIsNotADecision() {
        var guess = decision("Quizá subamos el precio")
        guess.level = .extracted
        let answer = BrainQuery.whatDidWeDecide(topic: "precio", in: [guess], at: now)
        #expect(answer.citations.isEmpty)
        #expect(answer.gap != nil)
    }

    @Test("when the last decision expired with nothing replacing it, it says exactly that")
    func expiredWithNoReplacement() {
        let expired = decision("Precio enterprise 1500", from: -1000, until: -10,
                               status: .superseded)
        let answer = BrainQuery.whatDidWeDecide(topic: "precio enterprise", in: [expired], at: now)

        #expect(answer.headline.contains("Ya no hay"))
        #expect(answer.gap == "Falta registrar la decisión vigente.")
        #expect(answer.citations == [expired])
    }

    @Test("knowing nothing is said plainly, not answered vaguely")
    func emptyBrain() {
        let answer = BrainQuery.whatDidWeDecide(topic: "pricing", in: [], at: now)
        #expect(answer.citations.isEmpty)
        #expect(answer.gap != nil)
        #expect(answer.headline.contains("No hay ninguna decisión"))
    }

    // MARK: - Prepare me

    @Test("a preparation gathers the meeting, the decisions and the open commitments")
    func prepare() {
        let meeting = CalendarEvent(id: "1", title: "Revisión con Acme",
                                    start: now.addingTimeInterval(3600),
                                    end: now.addingTimeInterval(7200),
                                    attendees: ["Andrés", "Marta"])
        let decision = decision("Descuento del 15% para Acme", entities: ["acme"])
        let commitment = MemoryObject(level: .committed, kind: .commitment,
                                      statement: "Enviar la propuesta antes del viernes",
                                      owner: "Jorge", createdAt: now.addingTimeInterval(-50),
                                      validFrom: now.addingTimeInterval(-50), entities: ["acme"])

        let answer = BrainQuery.prepare(subject: "Acme", in: [decision, commitment],
                                        events: [meeting], at: now)

        #expect(answer.headline.contains("Revisión con Acme"))
        #expect(answer.body.contains("Andrés"))
        #expect(answer.body.contains("Descuento del 15%"))
        #expect(answer.body.contains("Enviar la propuesta"))
        #expect(answer.gap?.contains("compromiso") == true, "an open commitment is worth flagging")
        #expect(answer.citations.count == 2)
    }

    @Test("preparing something the brain knows nothing about admits it")
    func prepareEmpty() {
        let answer = BrainQuery.prepare(subject: "Nike", in: [], events: [], at: now)
        #expect(answer.citations.isEmpty)
        #expect(answer.gap != nil)
    }

    @Test("a preparation ignores what is no longer true")
    func prepareSkipsExpired() {
        let expired = decision("Descuento del 30% para Acme", entities: ["acme"],
                               from: -1000, until: -10, status: .superseded)
        let answer = BrainQuery.prepare(subject: "Acme", in: [expired], at: now)
        #expect(!answer.body.contains("30%"), "a retired decision must not brief you")
    }

    @Test("an event is matched by title or by who is in it")
    func eventMatching() {
        let event = CalendarEvent(id: "1", title: "Sync semanal", start: now, end: now,
                                  attendees: ["Andrés Gómez"])
        #expect(event.matches("sync"))
        #expect(event.matches("andres"))
        #expect(!event.matches("zzzz"))
    }
}

@Suite("Asking the brain from the launcher")
@MainActor
struct BrainInLauncherTests {

    /// Real current time: these go through SearchEngine, which asks the brain about *now*.
    private let now = Date.now

    private func decision(_ statement: String, entities: [String]) -> MemoryObject {
        MemoryObject(level: .committed, kind: .decision, statement: statement,
                     source: "Reunión", owner: "Jorge",
                     createdAt: now.addingTimeInterval(-100),
                     validFrom: now.addingTimeInterval(-100), entities: entities)
    }

    @Test("asking a question outranks everything else on screen")
    func questionWins() {
        let input = SearchInput(
            applications: [Application(name: "Precios.app", path: "/Applications/Precios.app")],
            memories: [decision("Precio enterprise 2000", entities: ["pricing"])]
        )
        let results = SearchEngine.search("qué decidimos sobre precio enterprise", in: input)
        #expect(results.first?.kind == .answer)
        #expect(results.first?.payload.contains("Precio enterprise 2000") == true)
    }

    @Test("the answer says how many sources it stands on, or what is missing")
    func showsProvenance() {
        let withMemory = SearchEngine.search(
            "qué decidimos sobre pricing",
            in: SearchInput(memories: [decision("Precio 2000", entities: ["pricing"])])
        )
        #expect(withMemory.first?.subtitle.contains("fuente") == true)

        let empty = SearchEngine.search("qué decidimos sobre pricing", in: SearchInput())
        #expect(empty.first?.subtitle.contains("no sabe nada") == true,
                "an empty brain must say so, not answer vaguely")
    }

    @Test("preparing a meeting pulls the calendar in")
    func prepareUsesCalendar() {
        let event = CalendarEvent(id: "1", title: "Llamada con Acme",
                                  start: now.addingTimeInterval(3600),
                                  end: now.addingTimeInterval(7200), attendees: ["Andrés"])
        let input = SearchInput(memories: [decision("Descuento 15% para Acme", entities: ["acme"])],
                                events: [event])
        let results = SearchEngine.search("prepárame para Acme", in: input)

        #expect(results.first?.kind == .answer)
        #expect(results.first?.payload.contains("Andrés") == true)
        #expect(results.first?.payload.contains("Descuento 15%") == true)
    }

    @Test("writing 'recordar…' offers to capture it, and Return proposes it")
    func rememberByTyping() {
        var performed: [LauncherModel.Action] = []
        let model = LauncherModel(dataSource: { SearchInput() }, perform: { performed.append($0) })
        model.activate()
        model.query = "recordar que Acme pidió facturación anual"

        #expect(model.selected?.kind == .answer)
        model.handle(.enter)
        #expect(performed.contains {
            if case .remember(let text, _) = $0 { return text.contains("facturación anual") }
            return false
        })
    }

    @Test("an ordinary search is never hijacked by the brain")
    func ordinarySearchUntouched() {
        let input = SearchInput(
            applications: [Application(name: "Safari", path: "/Applications/Safari.app")],
            memories: [decision("Algo sobre navegadores", entities: ["safari"])]
        )
        let results = SearchEngine.search("safari", in: input)
        #expect(results.first?.kind != .answer, "typing a name is a search, not a question")
    }
}
