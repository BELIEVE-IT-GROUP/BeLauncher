import Foundation

public struct BELActionMatch: Sendable, Equatable {
    public let actionID: String
    public let argument: String
    public let confidence: Int

    public init(actionID: String, argument: String = "", confidence: Int) {
        self.actionID = actionID
        self.argument = argument
        self.confidence = confidence
    }
}

/// Resolves human launcher text without asking an LLM to choose a side effect.
public enum BELActionResolver {
    public static func resolve(_ query: String,
                               definitions: [BELActionDefinition] = BELActionCatalog.all)
    -> BELActionMatch? {
        let folded = Phrases.fold(query)
        // Two characters are enough for ordinary search, but not enough to infer an action.
        // Keeping this gate here prevents "sa" from becoming "salir" or another side effect.
        guard folded.count >= 3 else { return nil }

        let exact = definitions.filter { definition in
            definition.id == folded || definition.aliases.map(Phrases.fold).contains(folded)
        }
        if exact.count == 1, let definition = exact.first {
            return BELActionMatch(actionID: definition.id, confidence: 1_000)
        }
        if exact.count > 1 { return nil }

        let prefixed = definitions.compactMap { definition -> BELActionMatch? in
            let aliases = [definition.id] + definition.aliases.map(Phrases.fold)
            guard let alias = aliases
                .filter({ folded.hasPrefix($0 + " ") })
                .max(by: { $0.count < $1.count }) else { return nil }
            let argument = String(folded.dropFirst(alias.count))
                .trimmingCharacters(in: .whitespaces)
            return BELActionMatch(actionID: definition.id, argument: argument, confidence: 900)
        }
        if prefixed.count == 1, let match = prefixed.first { return match }
        if prefixed.count > 1 { return nil }

        let candidates = definitions.flatMap { definition in
            ([definition.id] + definition.aliases).compactMap { alias in
                Fuzzy.match(query: folded, candidate: alias).map {
                    (definition.id, $0.score)
                }
            }
        }
        guard let best = candidates.max(by: { $0.1 < $1.1 }), best.1 >= 35,
              candidates.filter({ $0.1 == best.1 }).count == 1 else { return nil }
        return BELActionMatch(actionID: best.0, confidence: best.1)
    }
}
