import Foundation

/// How *you* turn intention into action, learned from what you accept and what you rewrite.
///
/// The ambitious one, and the one most easily faked. Personalisation that means "we put your name
/// in the prompt" is decoration. What makes two people typing "prepara una propuesta" get genuinely
/// different results is a model of how each of them works: how long they write, how formal they
/// are, what they call things, what they consider urgent, what they always cut.
///
/// It learns from evidence rather than from a settings screen, because nobody can accurately
/// describe their own style and everybody demonstrates it constantly. Every trait here is inferred
/// from something observable: text you accepted unchanged, an edit you made to a draft, a file you
/// named, a meeting you declined.
///
/// Three limits keep this honest. A trait needs several observations before it is used at all —
/// one long email does not make you verbose. Every trait is visible and deletable in Settings, in
/// the same words used here. And the raw material is never stored: what is kept is the conclusion
/// ("escribe corto"), never the paragraph it came from.
public struct Trait: Sendable, Equatable, Identifiable, Codable {
    public var id: String { name }
    public let name: String
    public let value: String
    /// 0 to 1. Below `Trait.usableConfidence` it is watched, not applied.
    public let confidence: Double
    public let observations: Int
    public let updatedAt: Date

    public init(name: String, value: String, confidence: Double, observations: Int,
                updatedAt: Date = .now) {
        self.name = name
        self.value = value
        self.confidence = confidence
        self.observations = observations
        self.updatedAt = updatedAt
    }

    /// Enough evidence to change what the app produces. Four observations, same as a habit: below
    /// that, the app would be confidently wrong about someone based on a fluke.
    public static let minimumObservations = 4
    public static let usableConfidence = 0.6

    public var isUsable: Bool {
        observations >= Trait.minimumObservations && confidence >= Trait.usableConfidence
    }

    /// What the person reads in Settings. If a trait cannot be said in a sentence they would
    /// recognise, it has no business steering their work.
    public var explanation: String {
        switch name {
        case "writing.length": "Escribes \(value)."
        case "writing.formality": "Tu tono es \(value)."
        case "writing.greeting": value == "none"
            ? "You do not use filler greetings."
            : "You usually open with a greeting."
        case "writing.language": "You write in \(value)."
        case "files.naming": "You name files like this: \(value)."
        case "priority.urgent": "You treat as urgent whatever mentions: \(value)."
        case "meetings.accepts": "Aceptas reuniones \(value)."
        case "structure.proposal": "Your proposals go like this: \(value)."
        default: "\(name): \(value)"
        }
    }
}

public enum OperatingModel {

    // MARK: - Observing

    /// What a piece of the person's own writing says about how they write.
    ///
    /// Read from text they wrote or approved, never from a model's output: learning from your own
    /// generated text is how a system converges on its own voice and calls it yours.
    public static func observeWriting(_ text: String) -> [(name: String, value: String)] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else { return [] }

        var observed: [(String, String)] = []

        let words = trimmed.split(whereSeparator: \.isWhitespace).count
        observed.append(("writing.length", words < 60 ? "corto" : words < 200 ? "medio" : "largo"))

        let formal = ["usted", "cordialmente", "atentamente", "estimado", "le agradezco"]
        let casual = ["oye", "vale", "genial", "un abrazo", "gracias!", "jaja"]
        let lower = trimmed.lowercased()
        let formalHits = formal.count { lower.contains($0) }
        let casualHits = casual.count { lower.contains($0) }
        if formalHits != casualHits {
            observed.append(("writing.formality", formalHits > casualHits ? "formal" : "cercano"))
        }

        let greetings = ["hola", "buenos dias", "buenas tardes", "estimado", "hi ", "hello"]
        let opening = lower.prefix(40)
        observed.append(("writing.greeting",
                         greetings.contains { opening.contains($0) } ? "some" : "none"))

        return observed
    }

    /// What an edit says. The strongest signal in the product: a person changing a draft is telling
    /// you exactly what was wrong with it, and they do it without being asked.
    public static func observeEdit(before: String, after: String) -> [(name: String, value: String)] {
        let beforeWords = before.split(whereSeparator: \.isWhitespace).count
        let afterWords = after.split(whereSeparator: \.isWhitespace).count
        guard beforeWords > 10, afterWords > 0 else { return [] }

        var observed: [(String, String)] = []
        // A third shorter is a deliberate cut, not a tweak.
        if afterWords < beforeWords * 2 / 3 {
            observed.append(("writing.length", "corto"))
        } else if afterWords > beforeWords * 3 / 2 {
            observed.append(("writing.length", "largo"))
        }
        observed += observeWriting(after)
        return observed
    }

    /// What a filename says about how this person names things.
    public static func observeFilename(_ name: String) -> [(name: String, value: String)] {
        let base = (name as NSString).deletingPathExtension
        guard base.count > 3 else { return [] }

        if base.contains("-"), !base.contains(" ") {
            return [("files.naming", "con-guiones")]
        }
        if base.contains("_") {
            return [("files.naming", "con_guiones_bajos")]
        }
        if base.contains(" ") {
            return [("files.naming", "con espacios")]
        }
        if base.rangeOfCharacter(from: .uppercaseLetters) != nil {
            return [("files.naming", "EnCamello")]
        }
        return []
    }

    // MARK: - Learning

    /// Folds a new observation into what is already known.
    ///
    /// Agreement raises confidence, disagreement lowers it, and a trait that keeps being
    /// contradicted flips rather than clinging on. People change how they work; a model that cannot
    /// change with them becomes wrong and stays wrong.
    public static func fold(_ existing: Trait?, named name: String, observing value: String,
                            at date: Date = .now) -> Trait {
        guard let existing else {
            return Trait(name: name, value: value, confidence: 0.5, observations: 1,
                         updatedAt: date)
        }
        if existing.value == value {
            return Trait(name: existing.name, value: value,
                         confidence: min(1, existing.confidence + 0.12),
                         observations: existing.observations + 1, updatedAt: date)
        }
        let lowered = existing.confidence - 0.2
        guard lowered > 0.25 else {
            // Contradicted often enough: adopt the new value and start earning trust again.
            return Trait(name: existing.name, value: value, confidence: 0.5,
                         observations: existing.observations + 1, updatedAt: date)
        }
        return Trait(name: existing.name, value: existing.value, confidence: lowered,
                     observations: existing.observations + 1, updatedAt: date)
    }

    // MARK: - Applying

    /// Turns what is known into instructions a model can follow.
    ///
    /// Only usable traits get in. A half-learned preference steering someone's work is worse than
    /// no personalisation at all, because they cannot tell why the output changed.
    public static func systemPrompt(from traits: [Trait]) -> String {
        let usable = traits.filter(\.isUsable)
        guard !usable.isEmpty else { return "" }

        var lines = ["Write the way this person writes:"]
        for trait in usable.sorted(by: { $0.name < $1.name }) {
            switch trait.name {
            case "writing.length":
                lines.append(trait.value == "corto"
                    ? "- Very short. Straight to the point, no padding."
                    : trait.value == "largo"
                    ? "- Develops the ideas rather than telegraphing them."
                    : "- Medium length.")
            case "writing.formality":
                lines.append(trait.value == "formal"
                    ? "- Formal tone."
                    : "- Close, direct tone.")
            case "writing.greeting":
                lines.append(trait.value == "none"
                    ? "- No greetings or pleasantries. Start with what matters."
                    : "- Open with a short greeting.")
            case "writing.language":
                lines.append("- Write in \(trait.value).")
            case "structure.proposal":
                lines.append("- Preferred proposal structure: \(trait.value).")
            default:
                continue
            }
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : ""
    }

    /// Whether something counts as urgent *for this person*, rather than in general.
    public static func isUrgent(_ text: String, traits: [Trait]) -> Bool {
        guard let trait = traits.first(where: { $0.name == "priority.urgent" }), trait.isUsable
        else { return false }
        let markers = trait.value.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        let lower = text.lowercased()
        return markers.contains { !$0.isEmpty && lower.contains($0) }
    }
}

// MARK: - Storage

extension Store {

    public func traits() -> [Trait] {
        let rows = (try? database.query("SELECT * FROM preferences ORDER BY trait ASC")) ?? []
        return rows.map {
            Trait(name: $0.string("trait"), value: $0.string("value"),
                  confidence: $0.double("confidence"), observations: Int($0.int("observations")),
                  updatedAt: Date(timeIntervalSince1970: $0.double("updatedAt")))
        }
    }

    public func trait(named name: String) -> Trait? {
        traits().first { $0.name == name }
    }

    /// Records one observation about how this person works, folding it into what is known.
    public func observe(_ name: String, _ value: String, at date: Date = .now) {
        guard learningEnabled else { return }
        let folded = OperatingModel.fold(trait(named: name), named: name, observing: value, at: date)
        try? database.execute("""
            INSERT INTO preferences (trait, value, confidence, observations, updatedAt)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(trait) DO UPDATE SET
                value = excluded.value, confidence = excluded.confidence,
                observations = excluded.observations, updatedAt = excluded.updatedAt
            """,
            [.text(name), .text(folded.value), .double(folded.confidence),
             .int(Int64(folded.observations)), .double(date.timeIntervalSince1970)]
        )
    }

    public func observe(_ pairs: [(name: String, value: String)], at date: Date = .now) {
        for pair in pairs { observe(pair.name, pair.value, at: date) }
    }

    /// Off until asked for, like the habit log. Learning how someone works is not something to
    /// start doing because the app was installed.
    public var learningEnabled: Bool { setting("learning_enabled", default: false) }

    public func forgetTrait(_ name: String) {
        try? database.execute("DELETE FROM preferences WHERE trait = ?", [.text(name)])
    }

    public func forgetAllTraits() {
        try? database.execute("DELETE FROM preferences")
    }
}
