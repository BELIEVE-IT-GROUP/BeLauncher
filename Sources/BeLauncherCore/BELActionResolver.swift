import Foundation

public struct BELActionMatch: Sendable, Equatable {
    public let actionID: String
    public let argument: String
    /// Values keyed by the argument names in the action contract.
    public let arguments: [String: String]
    public let confidence: Int

    public init(actionID: String, argument: String = "", arguments: [String: String] = [:], confidence: Int) {
        self.actionID = actionID
        self.argument = argument
        self.arguments = arguments
        self.confidence = confidence
    }
}

/// Whether typed text resolved to one action, to several equally plausible ones, or to none.
public enum BELActionResolution: Sendable, Equatable {
    case match(BELActionMatch)
    /// More than one action matched equally well. IDs, sorted for stable output.
    case ambiguous([String])
}

/// Resolves human launcher text without asking an LLM to choose a side effect.
public enum BELActionResolver {
    public static func resolve(_ query: String,
                               definitions: [BELActionDefinition] = BELActionCatalog.all)
    -> BELActionMatch? {
        if case .match(let match) = resolveDetailed(query, definitions: definitions) { return match }
        return nil
    }

    /// Same resolution as `resolve`, but keeps "several actions matched equally well" distinct
    /// from "nothing matched" so the caller can tell the person instead of failing in silence.
    public static func resolveDetailed(_ query: String,
                                       definitions: [BELActionDefinition] = BELActionCatalog.all)
    -> BELActionResolution? {
        let folded = Phrases.fold(query)
        // Two characters are enough for ordinary search, but not enough to infer an action.
        guard folded.count >= 3 else { return nil }

        // The catalogue contains future contract seeds as well as runnable actions. Resolving a
        // seed would be a false positive, even when the user typed its stable ID exactly.
        let executable = definitions.filter {
            $0.availability != .unavailable && $0.adapter != .none
        }

        let exact = executable.filter { definition in
            definition.id == folded || definition.aliases.map(Phrases.fold).contains(folded)
        }
        if exact.count == 1, let definition = exact.first {
            guard let arguments = parseArguments("", for: definition) else { return nil }
            return .match(BELActionMatch(actionID: definition.id, arguments: arguments, confidence: 1_000))
        }
        if exact.count > 1 { return .ambiguous(exact.map(\.id).sorted()) }

        let prefixed = executable.compactMap { definition -> BELActionMatch? in
            let aliases = [definition.id] + definition.aliases.map(Phrases.fold)
            guard let alias = aliases
                .filter({ folded.hasPrefix($0 + " ") })
                .max(by: { $0.count < $1.count }) else { return nil }
            let argument = String(folded.dropFirst(alias.count))
                .trimmingCharacters(in: .whitespaces)
            guard let arguments = parseArguments(argument, for: definition) else { return nil }
            return BELActionMatch(actionID: definition.id, argument: argument,
                                  arguments: arguments, confidence: 900)
        }
        if prefixed.count == 1, let match = prefixed.first { return .match(match) }
        if prefixed.count > 1 { return .ambiguous(prefixed.map(\.actionID).sorted()) }

        // Fuzzy matching may choose only actions that need no missing positional argument. This
        // keeps a typo from silently opening, deleting or moving something without a path.
        let candidates = executable
            .filter { $0.arguments.allSatisfy { !$0.isRequired } }
            .compactMap { definition -> (String, Int)? in
                let matches = ([definition.id] + definition.aliases).compactMap { alias in
                    Fuzzy.match(query: folded, candidate: alias).map { (definition.id, $0.score) }
                }
                return matches.max(by: { $0.1 < $1.1 })
            }
        // Fuzzy inference is deliberately conservative because this result may execute a native
        // side effect. Exact IDs/aliases and explicit prefixes remain the fast paths.
        guard let best = candidates.max(by: { $0.1 < $1.1 }), best.1 >= 60 else { return nil }
        let tied = candidates.filter { $0.1 == best.1 }
        if tied.count > 1 { return .ambiguous(Set(tied.map(\.0)).sorted()) }
        return .match(BELActionMatch(actionID: best.0, confidence: best.1))
    }

    private static func parseArguments(_ raw: String, for definition: BELActionDefinition)
    -> [String: String]? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !definition.arguments.isEmpty else { return value.isEmpty ? [:] : nil }

        if definition.arguments.count == 1 {
            // AI verbs may take their text from the selected result/clipboard. Native actions may
            // never invent a path, app or destructive target from ambient context.
            guard !value.isEmpty || !definition.arguments[0].isRequired || definition.kind == .ai else {
                return nil
            }
            return value.isEmpty ? [:] : [definition.arguments[0].name: value]
        }

        // Multi-argument actions require explicit key=value syntax. Guessing whether a word is a
        // path, a flag or a second positional argument is unsafe at launcher speed.
        guard !value.isEmpty else {
            return definition.arguments.contains(where: \.isRequired) ? nil : [:]
        }
        var result: [String: String] = [:]
        for token in value.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let pair = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, !pair[1].isEmpty,
                  let spec = definition.arguments.first(where: {
                      Phrases.fold($0.name) == Phrases.fold(pair[0])
                  }) else { return nil }
            result[spec.name] = pair[1]
        }
        guard definition.arguments.filter(\.isRequired).allSatisfy({ result[$0.name] != nil }) else {
            return nil
        }
        return result
    }
}
