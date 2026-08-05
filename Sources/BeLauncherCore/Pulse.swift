import Foundation

/// What the company should be looking at and is not.
///
/// The only proactive thing in the product, and the one nobody else has. Everything else answers
/// a question; this asks one. It is deliberately last in the plan, because it needs accumulated
/// memory to say anything — a Pulse over an empty brain is noise, and noise teaches people to
/// ignore the feature forever.
public enum Pulse {

    public struct Signal: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, CaseIterable {
            /// Two live decisions that contradict each other.
            case contradiction
            /// A decision nobody has touched in a long time.
            case stale
            /// A commitment past its date with nothing recorded after it.
            case overdue
            /// Something asserted with no evidence behind it.
            case unsupported
            /// A project or client with no owner.
            case ownerless
            /// A decision that was retired and never replaced.
            case gap
        }

        public let id: String
        public let kind: Kind
        public let headline: String
        public let detail: String
        /// Higher means it deserves attention sooner.
        public let weight: Int
        public let objects: [MemoryObject]

        public init(id: String = UUID().uuidString, kind: Kind, headline: String, detail: String,
                    weight: Int, objects: [MemoryObject]) {
            self.id = id
            self.kind = kind
            self.headline = headline
            self.detail = detail
            self.weight = weight
            self.objects = objects
        }
    }

    /// How long a decision can sit untouched before it is worth re-reading. Six months: long
    /// enough not to nag, short enough that a stale price or policy gets caught.
    public static let staleAfter: TimeInterval = 180 * 24 * 3600

    public static func signals(
        for objects: [MemoryObject], at date: Date = .now, limit: Int = 8
    ) -> [Signal] {
        let live = objects.filter { $0.level == .committed && $0.isCurrent(at: date) }
        var signals: [Signal] = []

        signals += contradictions(in: live)
        // Overdue looks at everything committed, not at `live`: a commitment past its date has
        // stopped being current, which is exactly what makes it worth flagging.
        signals += overdue(in: objects.filter { $0.level == .committed }, at: date)
        signals += stale(in: live, at: date)
        signals += unsupported(in: live)
        signals += ownerless(in: live)
        signals += gaps(in: objects, at: date)

        return signals.sorted { $0.weight > $1.weight }.prefix(limit).map { $0 }
    }

    // MARK: - The checks

    /// Two live decisions on the same subject that say different things. This is the one that
    /// justifies the whole temporal model: without it, contradictions just accumulate quietly.
    static func contradictions(in live: [MemoryObject]) -> [Signal] {
        var found: [Signal] = []
        var seen = Set<String>()

        for (index, first) in live.enumerated() {
            for second in live[(index + 1)...] {
                guard first.kind == second.kind,
                      first.kind == .decision || first.kind == .policy else { continue }
                let shared = TeamBrain.topics(of: first).intersection(TeamBrain.topics(of: second))
                guard !shared.isEmpty else { continue }
                guard first.statement.caseInsensitiveCompare(second.statement) != .orderedSame else { continue }
                guard looksContradictory(first.statement, second.statement) else { continue }

                let key = [first.id, second.id].sorted().joined()
                guard seen.insert(key).inserted else { continue }

                found.append(Signal(
                    kind: .contradiction,
                    headline: "Dos versiones vigentes sobre \(shared.sorted().joined(separator: ", "))",
                    detail: "«\(first.statement)» y «\(second.statement)» están las dos en vigor. "
                          + "Una debería sustituir a la otra.",
                    weight: 100, objects: [first, second]
                ))
            }
        }
        return found
    }

    /// Both statements talk about the same thing but carry different numbers, or one negates what
    /// the other affirms. Blunt on purpose: the cost of asking is one glance.
    static func looksContradictory(_ first: String, _ second: String) -> Bool {
        let firstNumbers = numbers(in: first)
        let secondNumbers = numbers(in: second)
        if !firstNumbers.isEmpty, !secondNumbers.isEmpty, firstNumbers != secondNumbers {
            return true
        }
        let negations = ["no ", "nunca ", "sin ", "not ", "never "]
        let firstNegates = negations.contains { first.lowercased().contains($0) }
        let secondNegates = negations.contains { second.lowercased().contains($0) }
        return firstNegates != secondNegates
    }

    static func numbers(in text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 })
    }

    static func overdue(in objects: [MemoryObject], at date: Date) -> [Signal] {
        objects.filter { $0.kind == .commitment && $0.status == .active }
            .filter { commitment in
                guard let until = commitment.validUntil else { return false }
                return until < date
            }
            .map { commitment in
                Signal(kind: .overdue,
                       headline: "Compromiso vencido",
                       detail: "«\(commitment.statement)»"
                             + (commitment.owner.isEmpty ? "" : " · \(commitment.owner)"),
                       weight: 90, objects: [commitment])
            }
    }

    static func stale(in live: [MemoryObject], at date: Date) -> [Signal] {
        live.filter { $0.kind == .decision || $0.kind == .policy }
            .filter { date.timeIntervalSince($0.validFrom) > staleAfter }
            .map { object in
                let months = Int(date.timeIntervalSince(object.validFrom) / (30 * 24 * 3600))
                return Signal(kind: .stale,
                              headline: "Sin revisar desde hace \(months) meses",
                              detail: "«\(object.statement)». ¿Sigue siendo cierto?",
                              weight: 50, objects: [object])
            }
    }

    static func unsupported(in live: [MemoryObject]) -> [Signal] {
        live.filter { $0.kind == .decision && $0.evidence.isEmpty && $0.source.isEmpty }
            .map { object in
                Signal(kind: .unsupported,
                       headline: "Decisión sin respaldo",
                       detail: "«\(object.statement)» no tiene fuente ni evidencia. "
                             + "Dentro de un año nadie sabrá por qué se tomó.",
                       weight: 60, objects: [object])
            }
    }

    static func ownerless(in live: [MemoryObject]) -> [Signal] {
        live.filter { ($0.kind == .project || $0.kind == .commitment) && $0.owner.isEmpty }
            .map { object in
                Signal(kind: .ownerless,
                       headline: "Sin responsable",
                       detail: "«\(object.statement)» no tiene dueño.",
                       weight: 70, objects: [object])
            }
    }

    /// A decision that was retired and never replaced: the company stopped believing something
    /// and never said what it believes now.
    static func gaps(in objects: [MemoryObject], at date: Date) -> [Signal] {
        objects
            .filter { $0.status == .superseded && $0.supersededBy == nil && $0.kind == .decision }
            .map { object in
                Signal(kind: .gap,
                       headline: "Decisión caducada sin reemplazo",
                       detail: "«\(object.statement)» dejó de estar vigente y nadie registró "
                             + "qué la sustituye.",
                       weight: 80, objects: [object])
            }
    }

    // MARK: - Rendering

    public static func render(_ signals: [Signal]) -> String {
        guard !signals.isEmpty else {
            return "Nada que señalar. Ninguna contradicción, ningún compromiso vencido y nada "
                 + "sin revisar desde hace medio año."
        }
        return signals.map { signal in
            "**\(signal.headline)**\n\(signal.detail)"
        }.joined(separator: "\n\n")
    }
}

/// A sequence the user repeats, spotted so it can become a command.
///
/// The automation nobody had to design. It runs on a log that lives on this Mac, is readable in
/// Settings and can be wiped there — otherwise this feature would contradict the promise that
/// nothing is watching you.
public struct HabitDetector: Sendable {
    public struct Observation: Sendable, Equatable {
        public let steps: [String]
        public let times: Int

        public init(steps: [String], times: Int) {
            self.steps = steps
            self.times = times
        }
    }

    /// How many repetitions before offering. Four: three is coincidence often enough to annoy.
    public static let threshold = 4

    /// Finds runs of consecutive actions that repeat. `log` is oldest first.
    public static func habits(in log: [String], length: Int = 3,
                              threshold: Int = HabitDetector.threshold) -> [Observation] {
        guard log.count >= length * threshold else { return [] }

        var counts: [[String]: Int] = [:]
        for start in 0...(log.count - length) {
            let window = Array(log[start..<(start + length)])
            guard Set(window).count == length else { continue }   // ignore repeats of one thing
            counts[window, default: 0] += 1
        }
        return counts
            .filter { $0.value >= threshold }
            .map { Observation(steps: $0.key, times: $0.value) }
            .sorted { $0.times > $1.times }
    }
}
