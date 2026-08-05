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

    public static let all: [AIVerb] = [
        .init(id: "translate-es", title: "Traducir al español", symbol: "character.book.closed",
              instruction: "Traduce el texto al español neutro. Devuelve solo la traducción."),
        .init(id: "translate-en", title: "Traducir al inglés", symbol: "character.book.closed",
              instruction: "Translate the text into natural English. Return only the translation."),
        .init(id: "summarise", title: "Resumir", symbol: "text.redaction",
              instruction: "Resume el texto en como mucho cinco frases, sin adornos ni preámbulo. "
                         + "Devuelve solo el resumen.", replacesInput: false),
        .init(id: "bullets", title: "Convertir en puntos", symbol: "list.bullet",
              instruction: "Convierte el texto en una lista de puntos concisos. Solo la lista."),
        .init(id: "fix", title: "Corregir ortografía y gramática", symbol: "checkmark.circle",
              instruction: "Corrige ortografía, gramática y puntuación sin cambiar el tono ni el "
                         + "significado. Devuelve solo el texto corregido."),
        .init(id: "shorter", title: "Acortar", symbol: "arrow.down.right.and.arrow.up.left",
              instruction: "Reescribe el texto más corto y directo, conservando todo lo esencial. "
                         + "Devuelve solo el texto."),
        .init(id: "reply", title: "Redactar una respuesta", symbol: "arrowshape.turn.up.left",
              instruction: "Redacta una respuesta breve, clara y educada a este mensaje. "
                         + "Devuelve solo la respuesta.", replacesInput: false),
        .init(id: "explain", title: "Explicar", symbol: "questionmark.circle",
              instruction: "Explica en lenguaje llano qué dice o hace esto. Devuelve solo la "
                         + "explicación.", sensitivity: .ordinary, replacesInput: false),
        .init(id: "json", title: "Formatear JSON", symbol: "curlybraces",
              instruction: "Devuelve este JSON formateado y con sangría. Si no es JSON válido, "
                         + "di en una línea qué falla.", sensitivity: .ordinary),
        .init(id: "table", title: "Convertir en tabla", symbol: "tablecells",
              instruction: "Convierte estos datos en una tabla Markdown. Solo la tabla."),
        .init(id: "extract-tasks", title: "Sacar las tareas", symbol: "checklist",
              instruction: "Extrae las tareas y compromisos concretos con su responsable si se "
                         + "menciona. Una por línea. Si no hay ninguna, dilo en una línea.",
              sensitivity: .confidential, replacesInput: false),
    ]

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
        if trimmed.contains("@") || trimmed.lowercased().contains("hola") {
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

    public func run(_ verb: AIVerb, on text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IntelligenceError.emptyAnswer }

        let provider = try router.provider(for: verb.sensitivity, available: providers)
        return try await client.answer(
            IntelligenceRequest(
                system: "Eres una herramienta dentro de un launcher. Respondes solo con el "
                      + "resultado pedido, sin saludos, sin explicar lo que vas a hacer.",
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
    public var triggers: [String] {
        switch id {
        case "translate-es": ["traducir", "traduce", "traducir al espanol", "translate to spanish"]
        case "translate-en": ["traducir al ingles", "translate", "traduce al ingles", "to english"]
        case "summarise": ["resumir", "resume", "resumen", "summarise", "summarize"]
        case "bullets": ["puntos", "bullets", "vinetas"]
        case "fix": ["corregir", "corrige", "ortografia", "fix"]
        case "shorter": ["acortar", "acorta", "mas corto", "shorten"]
        case "reply": ["responder", "redactar respuesta", "reply"]
        case "explain": ["explicar", "explica", "explain"]
        case "json": ["json", "formatear json", "format json"]
        case "table": ["tabla", "table"]
        case "extract-tasks": ["tareas", "sacar tareas", "extract tasks"]
        default: [title.lowercased()]
        }
    }

    /// Finds the verb someone typed, and whatever text they typed after it.
    ///
    /// Returns nil for anything shorter than three characters so ordinary typing never turns into
    /// an AI offer halfway through a word.
    public static func typed(_ query: String) -> (verb: AIVerb, argument: String)? {
        let folded = query
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces)
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
