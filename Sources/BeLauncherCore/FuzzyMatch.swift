import Foundation

public struct FuzzyMatch: Sendable, Equatable {
    public let score: Int
    /// Indices of the matched characters in the candidate, for highlighting.
    public let matched: [Int]
}

public enum Fuzzy {

    /// Case- and diacritic-folding is the expensive part of matching, and it used to run once per
    /// candidate *and* once per keystroke for the query. With a real bookmark file (11k entries)
    /// that cost 95 ms per keystroke — visible stutter. Candidates fold once when indexed, the
    /// query folds once per search, and matching then works on plain character arrays.
    public static func folded(_ string: String) -> [Character] {
        Array(string.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current))
    }

    /// Subsequence match, case- and diacritic-insensitive.
    /// Rewards prefix hits, consecutive runs and word boundaries — the ranking people expect
    /// from a launcher ("gimp" → "GIMP", "sysp" → "System Preferences").
    public static func match(query: String, candidate: String) -> FuzzyMatch? {
        match(needle: folded(query), hay: folded(candidate))
    }

    /// A 27-bit fingerprint of which letters a string contains (a-z plus one bit for anything
    /// else). If the query needs a letter the candidate does not have, it cannot possibly match,
    /// and that is decided with one AND instead of a full scan.
    public static func mask(_ characters: [Character]) -> UInt32 {
        var mask: UInt32 = 0
        for character in characters {
            guard let ascii = character.asciiValue else { mask |= 1 << 26; continue }
            switch ascii {
            case 97...122: mask |= 1 << UInt32(ascii - 97)          // a-z
            case 48...57: mask |= 1 << 26                            // digits share the spare bit
            default: break                                           // spaces and punctuation: ignored
            }
        }
        return mask
    }

    /// Whether the query appears as a contiguous run inside the candidate. Subsequence matching
    /// is right for a few hundred app names, but against tens of thousands of bookmarks it makes
    /// almost everything "match" and buries what the user meant.
    public static func containsRun(needle: [Character], hay: [Character]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard needle.count <= hay.count else { return false }
        let limit = hay.count - needle.count
        var start = 0
        while start <= limit {
            var offset = 0
            while offset < needle.count, hay[start + offset] == needle[offset] { offset += 1 }
            if offset == needle.count { return true }
            start += 1
        }
        return false
    }

    /// True when the candidate cannot contain the query, decided in constant time.
    public static func cannotMatch(needleMask: UInt32, candidateMask: UInt32) -> Bool {
        needleMask & ~candidateMask != 0
    }

    /// Score only, without building the matched-index array. Used when thousands of candidates
    /// are ranked and only a handful will ever be shown: allocating a highlight array for every
    /// one of them was the real cost.
    public static func score(needle: [Character], hay: [Character]) -> Int? {
        guard !needle.isEmpty else { return 1 }
        guard needle.count <= hay.count else { return nil }
        var score = 0
        var hayIndex = 0
        var previousMatch = -2

        for character in needle {
            var found = false
            while hayIndex < hay.count {
                defer { hayIndex += 1 }
                guard hay[hayIndex] == character else { continue }
                score += 10
                if hayIndex == previousMatch + 1 { score += 12 }
                if hayIndex == 0 || isBoundary(hay[hayIndex - 1]) { score += 9 }
                if hayIndex == 0 { score += 6 }
                score -= min(hayIndex, 12)
                previousMatch = hayIndex
                found = true
                break
            }
            if !found { return nil }
        }
        score += max(0, 20 - hay.count / 2)
        if hay.count == needle.count { score += 25 }
        return score
    }

    /// Fast path for callers that already folded both sides.
    public static func match(needle: [Character], hay: [Character]) -> FuzzyMatch? {
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


}
