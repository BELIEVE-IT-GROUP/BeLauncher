import Foundation

public struct FuzzyMatch: Sendable, Equatable {
    public let score: Int
    /// Indices of the matched characters in the candidate, for highlighting.
    public let matched: [Int]
}

public enum Fuzzy {
    /// Subsequence match, case- and diacritic-insensitive.
    /// Rewards prefix hits, consecutive runs and word boundaries — the ranking people expect
    /// from a launcher ("gimp" → "GIMP", "sysp" → "System Preferences").
    public static func match(query: String, candidate: String) -> FuzzyMatch? {
        let needle = Array(fold(query))
        let hay = Array(fold(candidate))
        guard !needle.isEmpty else { return FuzzyMatch(score: 1, matched: []) }
        guard needle.count <= hay.count else { return nil }

        var matched: [Int] = []
        matched.reserveCapacity(needle.count)
        var score = 0
        var hayIndex = 0
        var previousMatch = -2

        for character in needle {
            var found = false
            while hayIndex < hay.count {
                defer { hayIndex += 1 }
                guard hay[hayIndex] == character else { continue }
                let isWordStart = hayIndex == 0 || isBoundary(hay[hayIndex - 1])
                score += 10
                if hayIndex == previousMatch + 1 { score += 12 }
                if isWordStart { score += 9 }
                if hayIndex == 0 { score += 6 }
                score -= min(hayIndex, 12)
                matched.append(hayIndex)
                previousMatch = hayIndex
                found = true
                break
            }
            if !found { return nil }
        }

        // Short, tight candidates beat long ones with the same hits.
        score += max(0, 20 - hay.count / 2)
        if hay.count == needle.count { score += 25 }
        return FuzzyMatch(score: score, matched: matched)
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character == " " || character == "-" || character == "_" || character == "." || character == "/"
    }

    private static func fold(_ string: String) -> String {
        string.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}
