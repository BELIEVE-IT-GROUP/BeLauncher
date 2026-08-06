import Foundation

/// The verbs people actually want applied to what they just copied or selected.
///
/// Not a chat box. A chat box makes you explain what you want every single time; a verb already
/// knows. Each one carries its own instruction and, crucially, its own sensitivity, so the router
/// can keep company material away from a cloud model without the user having to think about it.
public struct AIVerb: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let symbol: String
    public let instruction: String
    public let sensitivity: Sensitivity
    /// Whether the result is meant to replace what was there (rewrite) or to be new text.
    public let replacesInput: Bool

    public init(id: String, title: String, symbol: String, instruction: String,
                sensitivity: Sensitivity = .personal, replacesInput: Bool = true) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.instruction = instruction
        self.sensitivity = sensitivity
        self.replacesInput = replacesInput
    }

    /// Rebuilt on every access rather than held in a `static let`.
    ///
    /// A stored constant would capture whichever language was active the first time anything asked
    /// for a verb — which, for a menu bar app that starts before the user's choice is read from
    /// disk, is the wrong one. Fourteen small structs cost nothing next to being permanently in the
    /// wrong language until the next relaunch.
    ///
    /// The **instructions stay in English in both languages**, and that is deliberate. They are not
    /// read by a person; they are read by a model, and every model small enough to run on a laptop
    /// follows English instructions more reliably than Spanish ones. Each one ends up saying which
    /// language the *output* should be in, which is the input's — "Resumir" on a Spanish note must
    /// give back Spanish, whatever the menu bar says.
    public static var all: [AIVerb] {
        [
            .init(id: "translate-es", title: L("Translate to Spanish"), symbol: "character.book.closed",
                  instruction: "Translate the text into neutral Spanish. Return only the translation."),
            .init(id: "translate-en", title: L("Translate to English"), symbol: "character.book.closed",
                  instruction: "Translate the text into natural English. Return only the translation."),
            .init(id: "summarise", title: L("Summarise"), symbol: "text.redaction",
                  instruction: "Summarise the text in five sentences at most, with no preamble and no flourish. Return only the summary, in the language of the text.",
                  replacesInput: false),
            .init(id: "bullets", title: L("Turn into bullets"), symbol: "list.bullet",
                  instruction: "Turn the text into a list of tight bullet points, in the language of the text. Return only the list."),
            .init(id: "fix", title: L("Fix spelling and grammar"), symbol: "checkmark.circle",
                  instruction: "Fix spelling, grammar and punctuation without changing the tone or the meaning, and without changing the language. Return only the corrected text."),
            .init(id: "shorter", title: L("Make it shorter"), symbol: "arrow.down.right.and.arrow.up.left",
                  instruction: "Rewrite the text shorter and more direct, keeping everything that matters and the language it is written in. Return only the text."),
            .init(id: "reply", title: L("Draft a reply"), symbol: "arrowshape.turn.up.left",
                  instruction: "Draft a short, clear, courteous reply to this message, in the language the message is written in. Return only the reply.",
                  replacesInput: false),
            .init(id: "explain", title: L("Explain this"), symbol: "questionmark.circle",
                  instruction: "Explain in plain words what this says or does, in the language of the text. Return only the explanation.",
                  sensitivity: .ordinary, replacesInput: false),
            .init(id: "json", title: L("Format JSON"), symbol: "curlybraces",
                  instruction: "Return this JSON formatted and indented. If it is not valid JSON, say in one line what is wrong.",
                  sensitivity: .ordinary),
            .init(id: "table", title: L("Turn into a table"), symbol: "tablecells",
                  instruction: "Turn this data into a Markdown table. Only the table."),
            .init(id: "publish", title: L("Make it publishable"), symbol: "paperplane",
                  instruction: "Turn this note into something publishable: one headline and three or four short paragraphs, in the language of the note. No hashtags, no emoji, no \"a thread on\". Return only the text."),
            .init(id: "week-review", title: L("Review the week"), symbol: "calendar.badge.clock",
                  instruction: "From what follows, tell me what was left open, what is overdue, and where to start on Monday. Three short blocks, no introduction, in the language of the material."),
            .init(id: "extract-tasks", title: L("Pull out the tasks"), symbol: "checklist",
                  instruction: "Extract the concrete tasks and commitments with their owner where one is named. One per line, in the language of the text. If there are none, say so in one line.",
                  sensitivity: .confidential, replacesInput: false),
        ]
    }

    public static func named(_ id: String) -> AIVerb? { all.first { $0.id == id } }

    /// Verbs offered for a piece of text, most useful first. Kept short on purpose: a list of
    /// eleven options is a list nobody reads.
    public static func suggested(for text: String, limit: Int = 5) -> [AIVerb] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var ordered: [AIVerb] = []

        if DetailBuilder.looksLikeData(trimmed), trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            ordered += [named("json"), named("explain")].compactMap { $0 }
        }
        if trimmed.contains("\t") || trimmed.split(separator: "\n").count > 3 {
            ordered += [named("table"), named("summarise")].compactMap { $0 }
        }
        if trimmed.count > 400 {
            ordered += [named("summarise"), named("extract-tasks")].compactMap { $0 }
        }
        // A greeting or an address is what makes a block of text a message rather than a note. Both
        // languages are checked, always: an English inbox was invisible to this rule.
        let lowered = trimmed.lowercased()
        let greetings = ["hola", "buenas", "estimado", "hi ", "hello", "hey ", "dear "]
        if trimmed.contains("@") || greetings.contains(where: lowered.contains) {
            ordered += [named("reply")].compactMap { $0 }
        }

        // Then the everyday ones.
        ordered += ["fix", "translate-en", "translate-es", "summarise", "shorter"].compactMap(named)

        // Deduplicated once, at the end: several rules can suggest the same verb, and offering
        // "Resumir" twice in the same menu looks broken because it is.
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.id).inserted }.prefix(limit).map { $0 }
    }
}

/// Runs a verb. Separate from the client so the decision of *what to ask* and *who may answer*
/// stays testable without a model anywhere near it.
public struct AIVerbRunner: Sendable {
    public let client: IntelligenceClient
    public let router: ModelRouter
    public let providers: [IntelligenceProvider]
    /// The model to ask for, per provider id.
    ///
    /// Without this the app asked Ollama for the hardcoded `llama3.2` whether or not that was
    /// installed. Ollama then sat there trying to resolve a model nobody had, which read as the
    /// whole Mac freezing for a minute and ended in "error comunicándonos con el modelo". The app
    /// could already list what was installed; it just never used the answer.
    public let models: [String: String]

    public init(client: IntelligenceClient, router: ModelRouter,
                providers: [IntelligenceProvider], models: [String: String] = [:]) {
        self.client = client
        self.router = router
        self.providers = providers
        self.models = models
    }

    /// Said once, in English, because the model reads it and the user never does. It says nothing
    /// about which language to answer in: that belongs to each verb's instruction, which defers to
    /// the language of the text being worked on.
    static let systemPrompt = "You are a tool inside a launcher. You reply with the requested "
        + "result and nothing else: no greeting, no explaining what you are about to do."

    /// Runs the verb, reporting each fragment as it arrives.
    public func run(_ verb: AIVerb, on text: String,
                    onFragment: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IntelligenceError.emptyAnswer }

        let provider = try router.provider(for: verb.sensitivity, available: providers)
        let request = IntelligenceRequest(
            system: AIVerbRunner.systemPrompt,
            prompt: "\(verb.instruction)\n\n---\n\(trimmed)",
            sensitivity: verb.sensitivity
        )
        if let onFragment {
            return try await client.stream(request, using: provider, model: models[provider.id],
                                           onFragment: onFragment)
        }
        return try await client.answer(
            IntelligenceRequest(
                system: AIVerbRunner.systemPrompt,
                prompt: "\(verb.instruction)\n\n---\n\(trimmed)",
                sensitivity: verb.sensitivity
            ),
            using: provider,
            model: models[provider.id]
        )
    }
}

extension AIVerb {
    /// What someone types when they want this, in the words they would actually use.
    ///
    /// The verbs existed and were only reachable by selecting a result and pressing ⌘K — two steps
    /// nobody guesses. "Traducir esto" is what a person types; a launcher that answers it is a
    /// launcher, and one that requires the ritual is a keyboard exam.
    /// Both languages, always, whatever the interface is set to. A trigger list that follows the
    /// menu bar would mean the same person loses "resumir" the day they switch to English, and
    /// there is no upside to trade against that.
    public var triggers: [String] {
        switch id {
        case "translate-es": ["translate to spanish", "to spanish", "in spanish",
                              "traducir", "traduce", "traducir al espanol"]
        case "translate-en": ["translate to english", "translate", "to english", "in english",
                              "traducir al ingles", "traduce al ingles"]
        case "summarise": ["summarise", "summarize", "summary", "tldr",
                           "resumir", "resume", "resumen"]
        case "bullets": ["bullets", "bullet points", "puntos", "vinetas"]
        case "fix": ["fix", "proofread", "spelling", "corregir", "corrige", "ortografia"]
        case "shorter": ["shorten", "shorter", "tighten", "acortar", "acorta", "mas corto"]
        case "reply": ["reply", "draft a reply", "respond", "responder", "redactar respuesta"]
        case "explain": ["explain", "what is this", "explicar", "explica"]
        case "json": ["json", "format json", "formatear json"]
        case "table": ["table", "tabla"]
        case "publish": ["publish", "make it publishable", "publicable", "publicar"]
        case "week-review": ["review the week", "my week", "repasar la semana", "mi semana"]
        case "extract-tasks": ["tasks", "extract tasks", "todos",
                               "tareas", "sacar tareas"]
        default: [title.lowercased()]
        }
    }

    /// Finds the verb someone typed, and whatever text they typed after it.
    ///
    /// Returns nil for anything shorter than three characters so ordinary typing never turns into
    /// an AI offer halfway through a word.
    public static func typed(_ query: String) -> (verb: AIVerb, argument: String)? {
        let folded = Phrases.fold(query)
        guard folded.count >= 3 else { return nil }

        var best: (verb: AIVerb, argument: String, length: Int)?
        for verb in all {
            for trigger in verb.triggers where folded == trigger || folded.hasPrefix(trigger + " ") {
                // Longest trigger wins, so "traducir al ingles" never loses to "traducir".
                if best == nil || trigger.count > best!.length {
                    best = (verb, String(folded.dropFirst(trigger.count))
                        .trimmingCharacters(in: .whitespaces), trigger.count)
                }
            }
        }
        guard let best else { return nil }
        return (best.verb, best.argument)
    }
}
