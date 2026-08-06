import Foundation

/// Turning a day into sentences.
///
/// A brain that stores what happened can be *searched*. A brain that says what happened can be
/// *asked*. The difference is one pass: at night, over the episodes that settled, the local model
/// writes two or three short statements — *esta semana peleaste con auth en X, lo cerraste así* —
/// and each one carries the episode it came from.
///
/// This is where a memory product usually starts lying, so the rules are strict: a statement that
/// cannot point at its episode is thrown away, not shown with a caveat. An unattributable sentence
/// in a memory is worse than a missing one, because it is indistinguishable from a real one and it
/// teaches the person that the brain invents.
public struct Distillation: Sendable, Equatable {

    public struct Statement: Sendable, Equatable, Identifiable {
        public let id: String
        /// One sentence, in the words a person would use.
        public let text: String
        /// Episodes this came from. Never empty: that is enforced, not hoped for.
        public let sources: [String]
        public let day: Date

        public init(id: String? = nil, text: String, sources: [String], day: Date) {
            self.text = text
            self.sources = sources
            self.day = day
            self.id = id ?? "statement:" + Semantic.digest(text + sources.joined()).prefix(16)
        }
    }

    public let day: Date
    public let statements: [Statement]

    public init(day: Date, statements: [Statement]) {
        self.day = day
        self.statements = statements
    }

    // MARK: - Asking

    /// Nothing is distilled below this. One episode is a fact already in the index; distilling it
    /// produces a summary of a summary, which reads well and adds nothing.
    public static let minimumEpisodes = 2

    /// The prompt.
    ///
    /// Numbered episodes and a required citation on every line, for the same reason the retrieval
    /// prompt has them: the failure mode is a fluent paragraph half built from the notes and half
    /// from the model's own priors, with nothing to tell them apart afterwards.
    /// In English, for the same reasons as the retrieval prompt: small local models follow English
    /// instructions more reliably, and "do not invent" is the instruction that must survive.
    /// The statements themselves come out in the language of the episodes, because they are built
    /// from the words in them.
    public static func prompt(for episodes: [Episode]) -> (system: String, user: String) {
        let system = """
        Summarise a person's day from their work episodes. Write one to three sentences, each on \
        its own line, each ending with its citation [n]. Every sentence describes something that \
        was done, not something that was felt, and uses the words that appear in the episodes. \
        If the episodes do not support an honest sentence, write none. Do not invent outcomes, \
        do not guess why something was done, do not embellish. Write in the language the episodes \
        are in.
        """
        let listed = episodes.enumerated().map { index, episode in
            let when = DateFormatter.retrievalStamp().string(from: episode.start)
            let minutes = Int(episode.duration / 60)
            let touched = episode.signals
                .filter { $0.kind.describesWork }
                .map(\.title)
            var seen = Set<String>()
            let unique = touched.filter { seen.insert($0).inserted }.prefix(8)
            return "[\(index + 1)] \(when), \(minutes) min: \(unique.joined(separator: ", "))"
        }
        return (system, "Episodes:\n" + listed.joined(separator: "\n"))
    }

    /// Reads back what the model wrote, keeping only what it can prove.
    ///
    /// Every line has to carry a citation that points at an episode that was actually sent. A line
    /// citing `[9]` when eight went out is not a small formatting slip — it is the model writing
    /// from somewhere other than the material, which is the exact failure this whole pass has to
    /// avoid.
    public static func parse(_ answer: String, episodes: [Episode], day: Date) -> [Statement] {
        var result: [Statement] = []
        for raw in answer.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count >= 12 else { continue }

            let cited = citations(in: line)
            let valid = cited.filter { $0 >= 1 && $0 <= episodes.count }
            // No citation, or one that points nowhere: discard the line entirely.
            guard !valid.isEmpty, valid.count == cited.count else { continue }

            let text = strip(citations: line)
            guard text.count >= 12 else { continue }
            result.append(Statement(text: text, sources: valid.map { episodes[$0 - 1].id }, day: day))
        }
        return result
    }

    static func citations(in line: String) -> [Int] {
        var found: [Int] = []
        var digits = ""
        var inside = false
        for character in line {
            if character == "[" { inside = true; digits = ""; continue }
            if character == "]" {
                if inside, let number = Int(digits) { found.append(number) }
                inside = false
                continue
            }
            if inside { digits.append(character) }
        }
        return found
    }

    static func strip(citations line: String) -> String {
        var result = ""
        var inside = false
        for character in line {
            if character == "[" { inside = true; continue }
            if character == "]" { inside = false; continue }
            if !inside { result.append(character) }
        }
        return result
            .trimmingCharacters(in: CharacterSet(charactersIn: " -•·\t"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Which episodes are ready to be distilled.
    ///
    /// Only settled ones, and only those worth indexing. Distilling an episode that is still
    /// happening produces a statement that is rewritten an hour later, and anything cited in the
    /// meantime was cited from half a story.
    public static func ready(_ episodes: [Episode], now: Date = .now,
                             isWorthIt: (Episode) -> Bool = { _ in true }) -> [Episode] {
        episodes.filter { EpisodeBuilder.isSettled($0, now: now) && isWorthIt($0) }
    }
}
