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

        /// Both languages are listened for at once, from `Phrases`. Someone whose interface is in
        /// English still types "que decidimos sobre precios" when the decision was taken in
        /// Spanish, and the topic they are asking about is a Spanish phrase either way.
        ///
        /// The topic is cut from the *original* text, not the folded one, so "Acme Ltd." keeps its
        /// capitals and its accents on the way to the search.
        public static func detect(_ query: String) -> Intent {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            let folded = Phrases.fold(trimmed)
            guard trimmed.count >= 3 else { return .none }

            if let topic = original(after: Phrases.whatDidWeDecide, folded: folded, raw: trimmed) {
                return .whatDidWeDecide(topic: topic)
            }
            // "preparar reunión con Acme" lives here too. It used to fall through to a mission
            // that only summarised the words you typed, while this path reads the brain and the
            // calendar: two doors to the same question, one of them worse.
            if let subject = original(after: Phrases.prepare, folded: folded, raw: trimmed) {
                return .prepare(subject: subject)
            }
            if let text = original(after: Phrases.remember, folded: folded, raw: trimmed) {
                return .remember(text: text)
            }
            if Phrases.matches(anyOf: Phrases.pulse, in: folded) { return .pulse }
            return .none
        }

        /// Folding is diacritic- and case-insensitive but length-preserving, so an offset found in
        /// the folded text is valid in the original. Cutting the original is what keeps the
        /// accents in "reunión con José" from reaching the search stripped.
        private static func original(after prefixes: [String], folded: String,
                                     raw: String) -> String? {
            var longest = 0
            for prefix in prefixes where folded.hasPrefix(prefix) {
                longest = max(longest, prefix.count)
            }
            guard longest > 0, raw.count > longest else { return nil }
            let rest = String(raw.dropFirst(longest)).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
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
                    headline: L("There is no decision in force about “%@” any more", topic),
                    body: L("The last one was “%1$@” and it was superseded on %2$@. Nobody recorded what replaced it.",
                            previous.statement,
                            shortDate(previous.validUntil ?? previous.createdAt)),
                    citations: [previous],
                    gap: L("The decision in force is missing.")
                )
            }
            return Answer(
                headline: L("Nothing has been decided about “%@”", topic),
                body: L("When you decide, save it with “remember” and it will sit here with its date, its owner and what it replaced."),
                citations: [],
                gap: L("The brain knows nothing about this subject yet.")
            )
        }

        var lines = ["**\(latest.statement)**"]
        var citations = [latest]

        var details: [String] = []
        if !latest.owner.isEmpty { details.append(L("Decided by %@", latest.owner)) }
        details.append(L("in force since %@", shortDate(latest.validFrom)))
        if !latest.source.isEmpty { details.append(L("source: %@", latest.source)) }
        lines.append(details.joined(separator: " · "))

        // What it replaced, which is the part nobody else keeps.
        let replaced = latest.supersedes.compactMap { id in memories.first { $0.id == id } }
        if !replaced.isEmpty {
            lines.append("")
            lines.append(L("Replaced:"))
            for previous in replaced {
                lines.append("- \(previous.statement)")
                citations.append(previous)
            }
        }

        let others = current.filter { $0.id != latest.id }
        if !others.isEmpty {
            lines.append("")
            lines.append(L("Also in force on this:"))
            for other in others.prefix(4) {
                lines.append("- \(other.statement)")
                citations.append(other)
            }
        }

        return Answer(headline: L("Decision in force"), body: lines.joined(separator: "\n"),
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
                headline: L("I know nothing about “%@” yet", subject),
                body: L("When there are decisions, commitments or notes about this, they will be gathered here before the meeting."),
                citations: [],
                gap: L("No material on this subject.")
            )
        }

        var lines: [String] = []
        var citations: [MemoryObject] = []

        if let meeting {
            lines.append("**\(meeting.title)** · \(shortDateTime(meeting.start))")
            if !meeting.attendees.isEmpty {
                lines.append(L("With: %@", meeting.attendees.joined(separator: ", ")))
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

        section(L("Decisions in force:"), matching.filter { $0.kind == .decision })
        section(L("Open commitments:"), matching.filter { $0.kind == .commitment })
        section(L("Learnings:"), matching.filter { $0.kind == .learning })
        section(L("Notes:"), matching.filter { $0.kind == .note })

        let openCommitments = matching.filter { $0.kind == .commitment }
        let gap = openCommitments.isEmpty
            ? nil
            : L("%@ commitment(s) on this are still open.", String(openCommitments.count))

        return Answer(
            headline: meeting.map { L("Preparation: %@", $0.title) }
                ?? L("What we know about %@", subject),
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

    /// Dates follow the interface language, not the machine's region. Someone running the app in
    /// English on a Mac set to Spain wants "5 Aug", and someone in Miami reading the Spanish
    /// interface wants "5 ago" — the setting they made is the one that should decide.
    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().locale(Loc.language.locale))
    }

    static func shortDateTime(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).hour().minute()
            .locale(Loc.language.locale))
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
