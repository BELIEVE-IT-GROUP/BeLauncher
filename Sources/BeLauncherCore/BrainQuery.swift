import Foundation

/// The three questions the brain has to answer well before it is worth anything:
/// what did we decide, prepare me, and remember this.
///
/// Every answer is assembled from objects that exist, and every claim carries the object it came
/// from. An answer without a source is a guess wearing a suit, and the whole point of a company
/// brain is being able to tell those apart.
public enum BrainQuery {

    public struct Answer: Sendable, Equatable {
        public let headline: String
        public let body: String
        /// The objects this answer stands on, in the order they are cited.
        public let citations: [MemoryObject]
        /// Filled when the brain has nothing to say, so the UI can be honest instead of vague.
        public let gap: String?

        public init(headline: String, body: String, citations: [MemoryObject], gap: String? = nil) {
            self.headline = headline
            self.body = body
            self.citations = citations
            self.gap = gap
        }
    }

    /// Recognises the shape of what the user typed. Deliberately small: three intents beat a
    /// natural-language parser that is wrong in ways nobody can predict.
    public enum Intent: Equatable, Sendable {
        case whatDidWeDecide(topic: String)
        case prepare(subject: String)
        case remember(text: String)
        case pulse
        case none

        public static func detect(_ query: String) -> Intent {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            let folded = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                         locale: .current)
            guard trimmed.count >= 3 else { return .none }

            for prefix in ["que decidimos sobre ", "que decidimos de ", "que decidimos ",
                           "what did we decide about ", "what did we decide "] where folded.hasPrefix(prefix) {
                return .whatDidWeDecide(topic: String(trimmed.dropFirst(prefix.count)))
            }
            // "preparar reunión con Acme" lives here too. It used to fall through to a mission
            // that only summarised the words you typed, while this path reads the brain and the
            // calendar: two doors to the same question, one of them worse.
            for prefix in ["preparame para ", "preparame ", "preparar reunion con ",
                           "preparar reunion ", "prepara ", "prepare me for ", "prepare for ",
                           "prepare "] where folded.hasPrefix(prefix) {
                return .prepare(subject: String(trimmed.dropFirst(prefix.count)))
            }
            for prefix in ["recordar ", "recuerda ", "remember "] where folded.hasPrefix(prefix) {
                return .remember(text: String(trimmed.dropFirst(prefix.count)))
            }
            for word in ["pulse", "pulso", "que se me escapa", "que esta en riesgo",
                         "riesgos"] where folded == word || folded.hasPrefix(word) {
                return .pulse
            }
            return .none
        }
    }

    // MARK: - What did we decide

    public static func whatDidWeDecide(
        topic: String, in memories: [MemoryObject], at date: Date = .now
    ) -> Answer {
        let matching = relevant(topic, in: memories, kinds: [.decision, .policy])
        let current = matching.filter { $0.isCurrent(at: date) && $0.level == .committed }

        guard let latest = current.sorted(by: { $0.validFrom > $1.validFrom }).first else {
            let past = matching.filter { $0.status == .superseded }
            if let previous = past.first {
                return Answer(
                    headline: "Ya no hay una decisión vigente sobre “\(topic)”",
                    body: "La última fue «\(previous.statement)» y quedó sustituida el "
                        + "\(shortDate(previous.validUntil ?? previous.createdAt)). "
                        + "Nadie registró la que la reemplazó.",
                    citations: [previous],
                    gap: "Falta registrar la decisión vigente."
                )
            }
            return Answer(
                headline: "No hay ninguna decisión registrada sobre “\(topic)”",
                body: "Cuando la toméis, guardadla con «recordar» y quedará aquí con su fecha, "
                    + "su dueño y lo que sustituye.",
                citations: [],
                gap: "El cerebro no sabe nada de este tema todavía."
            )
        }

        var lines = ["**\(latest.statement)**"]
        var citations = [latest]

        var details: [String] = []
        if !latest.owner.isEmpty { details.append("Decidido por \(latest.owner)") }
        details.append("vigente desde el \(shortDate(latest.validFrom))")
        if !latest.source.isEmpty { details.append("fuente: \(latest.source)") }
        lines.append(details.joined(separator: " · "))

        // What it replaced, which is the part nobody else keeps.
        let replaced = latest.supersedes.compactMap { id in memories.first { $0.id == id } }
        if !replaced.isEmpty {
            lines.append("")
            lines.append("Sustituyó a:")
            for previous in replaced {
                lines.append("- \(previous.statement)")
                citations.append(previous)
            }
        }

        let others = current.filter { $0.id != latest.id }
        if !others.isEmpty {
            lines.append("")
            lines.append("También vigente sobre esto:")
            for other in others.prefix(4) {
                lines.append("- \(other.statement)")
                citations.append(other)
            }
        }

        return Answer(headline: "Decisión vigente", body: lines.joined(separator: "\n"),
                      citations: citations)
    }

    // MARK: - Prepare me

    public static func prepare(
        subject: String, in memories: [MemoryObject], events: [CalendarEvent] = [], at date: Date = .now
    ) -> Answer {
        let matching = relevant(subject, in: memories, kinds: nil)
            .filter { $0.isCurrent(at: date) }
        let meeting = events.first { $0.matches(subject) }

        guard !matching.isEmpty || meeting != nil else {
            return Answer(
                headline: "Todavía no sé nada de “\(subject)”",
                body: "Cuando haya decisiones, compromisos o notas sobre esto, aparecerán aquí "
                    + "reunidas antes de la reunión.",
                citations: [],
                gap: "Sin material sobre este asunto."
            )
        }

        var lines: [String] = []
        var citations: [MemoryObject] = []

        if let meeting {
            lines.append("**\(meeting.title)** · \(shortDateTime(meeting.start))")
            if !meeting.attendees.isEmpty {
                lines.append("Con: \(meeting.attendees.joined(separator: ", "))")
            }
            lines.append("")
        }

        func section(_ title: String, _ objects: [MemoryObject]) {
            guard !objects.isEmpty else { return }
            lines.append(title)
            for object in objects.prefix(5) {
                lines.append("- \(object.statement)")
                citations.append(object)
            }
            lines.append("")
        }

        section("Decisiones vigentes:", matching.filter { $0.kind == .decision })
        section("Compromisos abiertos:", matching.filter { $0.kind == .commitment })
        section("Aprendizajes:", matching.filter { $0.kind == .learning })
        section("Notas:", matching.filter { $0.kind == .note })

        let openCommitments = matching.filter { $0.kind == .commitment }
        let gap = openCommitments.isEmpty
            ? nil
            : "Hay \(openCommitments.count) compromiso(s) sin cerrar sobre esto."

        return Answer(
            headline: meeting.map { "Preparación: \($0.title)" } ?? "Lo que sabemos de \(subject)",
            body: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            citations: citations,
            gap: gap
        )
    }

    // MARK: - Shared

    public static func relevant(
        _ topic: String, in memories: [MemoryObject], kinds: Set<MemoryObject.Kind>?
    ) -> [MemoryObject] {
        let needle = Fuzzy.folded(topic)
        guard !needle.isEmpty else { return [] }

        return memories
            .filter { kinds == nil || kinds!.contains($0.kind) }
            .compactMap { memory -> (MemoryObject, Int)? in
                let haystack = Fuzzy.folded(
                    memory.statement + " " + memory.entities.joined(separator: " ") + " " + memory.body
                )
                guard let score = Fuzzy.score(needle: needle, hay: haystack) else { return nil }
                return (memory, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func shortDateTime(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).hour().minute())
    }
}

/// The calendar entry a preparation is built around. Kept here, free of EventKit, so preparing a
/// meeting can be tested without a calendar on the machine.
public struct CalendarEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let attendees: [String]
    public let notes: String

    public init(id: String, title: String, start: Date, end: Date,
                attendees: [String] = [], notes: String = "") {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.notes = notes
    }

    public func matches(_ subject: String) -> Bool {
        let needle = Fuzzy.folded(subject)
        let haystack = Fuzzy.folded(title + " " + attendees.joined(separator: " "))
        return Fuzzy.score(needle: needle, hay: haystack) != nil
    }
}
