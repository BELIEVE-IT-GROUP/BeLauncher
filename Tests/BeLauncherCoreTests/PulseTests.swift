import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Company Pulse")
struct PulseTests {

    private let now = Date.now

    private func object(_ statement: String, kind: MemoryObject.Kind = .decision,
                        entities: [String] = ["pricing"], owner: String = "Jorge",
                        source: String = "Reunión", days: Double = -10,
                        until: Double? = nil, status: MemoryObject.Status = .active,
                        supersededBy: String? = nil, evidence: [String] = ["nota"]) -> MemoryObject {
        MemoryObject(level: .committed, kind: kind, statement: statement,
                     source: source, owner: owner,
                     createdAt: now.addingTimeInterval(days * 86_400),
                     validFrom: now.addingTimeInterval(days * 86_400),
                     validUntil: until.map { now.addingTimeInterval($0 * 86_400) },
                     status: status, supersededBy: supersededBy,
                     entities: entities, evidence: evidence)
    }

    // MARK: - Contradictions

    @Test("two live decisions with different numbers on the same subject are surfaced")
    func contradiction() {
        let signals = Pulse.signals(for: [
            object("El plan Pro cuesta 49 al mes"),
            object("El plan Pro cuesta 59 al mes"),
        ], at: now)

        let contradiction = signals.first { $0.kind == .contradiction }
        #expect(contradiction != nil, "this is what the whole temporal model is for")
        #expect(contradiction?.objects.count == 2)
        #expect(contradiction?.weight == 100, "nothing deserves attention sooner")
    }

    @Test("a decision and its replacement are not a contradiction")
    func supersededIsNotAContradiction() {
        let old = object("Precio 49", status: .superseded, supersededBy: "new-id")
        let new = object("Precio 59")
        #expect(!Pulse.signals(for: [old, new], at: now).contains { $0.kind == .contradiction })
    }

    @Test("decisions about different subjects never collide")
    func differentSubjects() {
        let signals = Pulse.signals(for: [
            object("El plan Pro cuesta 49", entities: ["pricing"]),
            object("Contratamos 3 personas", entities: ["hiring"]),
        ], at: now)
        #expect(!signals.contains { $0.kind == .contradiction })
    }

    // MARK: - The other checks

    @Test("a commitment past its date is flagged")
    func overdue() {
        let signals = Pulse.signals(for: [
            object("Enviar la propuesta a Acme", kind: .commitment, entities: ["acme"],
                   days: -30, until: -5),
        ], at: now)
        #expect(signals.contains { $0.kind == .overdue })
    }

    @Test("a decision nobody has touched in half a year is worth re-reading")
    func stale() {
        let signals = Pulse.signals(for: [object("Precio enterprise 2000", days: -300)], at: now)
        let stale = signals.first { $0.kind == .stale }
        #expect(stale != nil)
        #expect(stale?.headline.contains("meses") == true)

        #expect(!Pulse.signals(for: [object("Reciente", days: -30)], at: now)
            .contains { $0.kind == .stale })
    }

    @Test("a decision with no source will be a mystery in a year")
    func unsupported() {
        let signals = Pulse.signals(for: [object("Algo se decidió", source: "", evidence: [])],
                                    at: now)
        #expect(signals.contains { $0.kind == .unsupported })
    }

    @Test("work with nobody's name on it is flagged")
    func ownerless() {
        let signals = Pulse.signals(for: [
            object("Migrar el CRM", kind: .project, owner: ""),
        ], at: now)
        #expect(signals.contains { $0.kind == .ownerless })
    }

    @Test("a decision retired with nothing replacing it is a hole in the brain")
    func gap() {
        let signals = Pulse.signals(for: [
            object("Precio enterprise 1500", days: -60, until: -30, status: .superseded),
        ], at: now)
        #expect(signals.contains { $0.kind == .gap })
    }

    // MARK: - Behaviour as a whole

    @Test("an empty brain produces silence, not invented concern")
    func quietWhenEmpty() {
        #expect(Pulse.signals(for: [], at: now).isEmpty)
        #expect(Pulse.render([]).contains("Nada que señalar"))
    }

    @Test("a healthy brain says nothing")
    func quietWhenHealthy() {
        let signals = Pulse.signals(for: [object("Precio enterprise 2000", days: -20)], at: now)
        #expect(signals.isEmpty, "a Pulse that always finds something teaches people to ignore it")
    }

    @Test("the most urgent signals come first and the list stays short")
    func rankedAndBounded() {
        var objects: [MemoryObject] = []
        for index in 0..<20 {
            objects.append(object("Cosa vieja \(index)", entities: ["tema\(index)"], days: -400))
        }
        objects += [object("Precio 49"), object("Precio 59")]

        let signals = Pulse.signals(for: objects, at: now)
        #expect(signals.count <= 8, "a wall of alerts is the same as no alerts")
        #expect(signals.first?.kind == .contradiction)
    }

    // MARK: - Habits

    @Test("a sequence repeated enough times becomes an offer")
    func detectsHabit() {
        let routine = ["open:Numbers", "clip:copy", "open:Mail"]
        let log = Array(repeating: routine, count: 5).flatMap { $0 }
        let habits = HabitDetector.habits(in: log)

        #expect(habits.first?.steps == routine)
        #expect(habits.first?.times ?? 0 >= 4)
    }

    @Test("three times is coincidence, not a habit")
    func needsEnoughRepetitions() {
        let log = Array(repeating: ["a", "b", "c"], count: 3).flatMap { $0 }
        #expect(HabitDetector.habits(in: log).isEmpty)
    }

    @Test("doing the same thing over and over is not a sequence")
    func ignoresRepeatsOfOneAction() {
        #expect(HabitDetector.habits(in: Array(repeating: "clip:copy", count: 40)).isEmpty)
    }

    @Test("a short log yields nothing rather than noise")
    func shortLog() {
        #expect(HabitDetector.habits(in: ["a", "b"]).isEmpty)
    }
}

@Suite("Asking for the Pulse")
@MainActor
struct PulseInLauncherTests {

    private func object(_ statement: String, entities: [String]) -> MemoryObject {
        MemoryObject(level: .committed, kind: .decision, statement: statement,
                     source: "Reunión", owner: "Jorge",
                     createdAt: .now.addingTimeInterval(-86_400),
                     validFrom: .now.addingTimeInterval(-86_400), entities: entities)
    }

    @Test("asking for the pulse is recognised in several ways")
    func intent() {
        #expect(BrainQuery.Intent.detect("pulse") == .pulse)
        #expect(BrainQuery.Intent.detect("pulso") == .pulse)
        #expect(BrainQuery.Intent.detect("qué está en riesgo") == .pulse)
        #expect(BrainQuery.Intent.detect("safari") != .pulse)
    }

    @Test("it reports what contradicts itself, first")
    func surfacesContradictions() {
        let input = SearchInput(memories: [
            object("El plan Pro cuesta 49 al mes", entities: ["pricing"]),
            object("El plan Pro cuesta 59 al mes", entities: ["pricing"]),
        ])
        let result = SearchEngine.search("pulse", in: input).first
        #expect(result?.kind == .answer)
        #expect(result?.payload.contains("49") == true)
        #expect(result?.payload.contains("59") == true)
    }

    @Test("a healthy brain gets silence, not invented concern")
    func quietWhenHealthy() {
        let result = SearchEngine.search("pulse", in: SearchInput(memories: [
            object("Precio enterprise 2000", entities: ["pricing"]),
        ])).first
        #expect(result?.title == "Nada que señalar")
    }
}
