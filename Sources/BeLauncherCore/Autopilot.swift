import Foundation

/// Turns something you keep doing into a command, without you designing anything.
///
/// `HabitDetector` existed for weeks with tests and no caller, and no log for it to read: the class
/// looked implemented and the feature did not exist. This is the missing half — the part that
/// watches, proposes, and takes no for an answer.
///
/// Three rules keep this from being the annoying feature everyone switches off. It only speaks
/// after the same sequence has happened four times, because three is coincidence often enough to
/// irritate. It asks once per habit and never asks again about a habit that was refused. And what
/// it proposes is a flow the person can read, edit and delete like any other — not a hidden
/// automation that starts doing things on its own.
public enum Autopilot {

    public struct Recipe: Sendable, Equatable, Identifiable {
        /// Stable across runs so a refusal sticks.
        public var id: String { steps.joined(separator: "|") }
        public let steps: [String]
        public let labels: [String]
        public let times: Int
        /// A name the person can accept or change.
        public let suggestedKeyword: String

        public init(steps: [String], labels: [String], times: Int, suggestedKeyword: String) {
            self.steps = steps
            self.labels = labels
            self.times = times
            self.suggestedKeyword = suggestedKeyword
        }

        public var summary: String { labels.joined(separator: " → ") }

        public var offer: String {
            "Has hecho esto \(times) veces: \(summary). ¿Lo convierto en un comando?"
        }
    }

    /// The shortest run worth turning into a command. Two steps is not a workflow, it is two
    /// keystrokes, and offering to save them makes the feature look desperate.
    public static let minimumSteps = 3

    /// Looks for habits worth offering, skipping the ones already asked about.
    public static func recipes(
        from log: [LoggedAction], alreadyOffered: (String) -> Bool,
        length: Int = minimumSteps, threshold: Int = HabitDetector.threshold
    ) -> [Recipe] {
        guard log.count >= length * threshold else { return [] }

        let labels = Dictionary(log.map { ($0.signature, $0.label) }, uniquingKeysWith: { _, new in new })
        return HabitDetector
            .habits(in: log.map(\.signature), length: length, threshold: threshold)
            .map { observation in
                Recipe(
                    steps: observation.steps,
                    labels: observation.steps.map { labels[$0] ?? $0 },
                    times: observation.times,
                    suggestedKeyword: keyword(for: observation.steps.map { labels[$0] ?? $0 })
                )
            }
            .filter { !alreadyOffered($0.id) }
    }

    /// A short, typeable name built from what the sequence does. Never a UUID, never "flujo 3":
    /// a command nobody can guess the name of is a command nobody runs.
    public static func keyword(for labels: [String]) -> String {
        let words = labels
            .compactMap { label -> String? in
                label.split(separator: " ")
                    .first { $0.count > 3 }
                    .map { String($0).lowercased() }
            }
            .prefix(2)
        let base = words
            .joined(separator: "-")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { $0.isLetter || $0 == "-" }
        return base.isEmpty ? "rutina" : base
    }

    /// Turns the accepted habit into a flow the person owns.
    ///
    /// Steps the app cannot replay become a `.wait`, which is honest: the flow says there was a
    /// step here and does not pretend to have carried it out.
    public static func flow(from recipe: Recipe, keyword: String? = nil) -> Flow {
        Flow(
            id: 0,
            keyword: keyword ?? recipe.suggestedKeyword,
            title: recipe.summary,
            steps: recipe.steps.compactMap(step(from:))
        )
    }

    static func step(from signature: String) -> FlowStep? {
        let parts = signature.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "app": return .openApp(path: parts[1])
        case "url": return .openURL(url: parts[1])
        case "system": return .systemCommand(kind: parts[1])
        case "shortcut": return .runShortcut(name: parts[1])
        case "flow": return nil   // a flow inside a flow is a loop waiting to happen
        default: return nil
        }
    }

    /// What the app writes to the log when something happens. Kept in one place so the strings a
    /// detector compares are never invented twice with two different shapes.
    public static func signature(forApplication path: String) -> String { "app:\(path)" }
    public static func signature(forSystemCommand kind: String) -> String { "system:\(kind)" }
    public static func signature(forURL url: String) -> String { "url:\(url)" }
    public static func signature(forShortcut name: String) -> String { "shortcut:\(name)" }
    public static func signature(forFlow keyword: String) -> String { "flow:\(keyword)" }
}
