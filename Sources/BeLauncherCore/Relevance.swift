import Foundation

/// Deciding what is worth remembering.
///
/// Most of what happens on a Mac is noise. A day contains a few hundred moments and perhaps eight
/// that anyone would ever ask about, and if all of them weigh the same the eight drown: a question
/// about a decision returns twenty browser tabs that were open for three seconds on the same
/// subject, because twenty near-identical passages beat one good one on any ranking.
///
/// A brain that remembers everything equally remembers nothing. So this scores, and what does not
/// clear the bar is kept on disk but stays out of the index — recoverable, never retrieved.
///
/// Everything here is measured from behaviour rather than from content. No text is read, no model
/// is asked, nothing is inferred about what you were thinking. Time spent, coming back, taking
/// something with you: three signals that are cheap, honest and hard to fake.
public enum Relevance {

    public struct Signals: Sendable, Equatable {
        /// Seconds inside it.
        public let dwell: TimeInterval
        /// How many separate days it was touched. The strongest signal there is.
        public let daysSeen: Int
        /// Whether something was copied out of it.
        public let copiedFrom: Bool
        /// Whether it sits next to things that already matter.
        public let neighbours: Int
        /// Whether a person said so out loud, by remembering it or pinning it.
        public let markedByHand: Bool

        public init(dwell: TimeInterval = 0, daysSeen: Int = 1, copiedFrom: Bool = false,
                    neighbours: Int = 0, markedByHand: Bool = false) {
            self.dwell = dwell
            self.daysSeen = daysSeen
            self.copiedFrom = copiedFrom
            self.neighbours = neighbours
            self.markedByHand = markedByHand
        }
    }

    /// Below this, something is kept but not indexed.
    ///
    /// Set where a single unremarkable visit lands. The bar has to be low: the cost of dropping
    /// something that mattered is a question that cannot be answered and no way to find out why,
    /// while the cost of keeping something that did not is one more row in a table.
    public static let bar: Double = 0.30

    /// A minute is where a glance becomes reading. Below it, dwell says almost nothing.
    public static let meaningfulDwell: TimeInterval = 60
    /// Past twenty minutes the extra time stops meaning more. Leaving a window open over lunch
    /// should not outrank a focused ten minutes.
    public static let saturatingDwell: TimeInterval = 20 * 60

    public static func score(_ signals: Signals) -> Double {
        // Saying so by hand ends the argument. Every automatic signal exists to guess at what a
        // person would have said, so when they have actually said it, guessing stops.
        if signals.markedByHand { return 1 }

        var total = 0.0

        // Time, flattened at both ends: a glance is worth nothing and an afternoon is not worth
        // twenty times a focused ten minutes.
        if signals.dwell > meaningfulDwell {
            let span = min(signals.dwell, saturatingDwell) - meaningfulDwell
            total += 0.30 * (span / (saturatingDwell - meaningfulDwell))
        }

        // Coming back on another day is what separates work from a detour, and it is the one
        // signal that cannot be produced by accident: nobody reopens something by mistake a week
        // later. Weighted highest for that reason.
        if signals.daysSeen >= 2 { total += 0.35 }
        if signals.daysSeen >= 4 { total += 0.15 }

        // Taking something with you is an act, not a behaviour. It says this was useful.
        if signals.copiedFrom { total += 0.25 }

        // Company. Something touched alongside four other things belongs to a piece of work;
        // something alone is usually a detour.
        total += min(Double(signals.neighbours), 4) * 0.05

        return min(total, 1)
    }

    public static func isWorthIndexing(_ signals: Signals) -> Bool {
        score(signals) >= bar
    }

    /// Why something did or did not make it, in words.
    ///
    /// Written for the graph view, where somebody looks at their own brain and asks why a thing
    /// they remember is not in it. "No llegó al umbral" is not an answer anybody can act on.
    public static func explain(_ signals: Signals) -> String {
        if signals.markedByHand { return L("You kept it yourself.") }
        var reasons: [String] = []
        if signals.daysSeen >= 2 { reasons.append(L("you came back on %@ different days", String(signals.daysSeen))) }
        if signals.dwell > meaningfulDwell {
            reasons.append(L("you stayed %@ minutes", String(Int(signals.dwell / 60))))
        }
        if signals.copiedFrom { reasons.append(L("you copied something from there")) }
        if signals.neighbours > 0 { reasons.append(L("it turns up next to %@ other things", String(signals.neighbours))) }

        guard !reasons.isEmpty else {
            return L("You went past it once for a few seconds, so it did not make it into the search.")
        }
        return reasons.joined(separator: ", ").prefix(1).uppercased() + reasons.joined(separator: ", ").dropFirst() + "."
    }

    /// Signals from an episode, without reading a word of its contents.
    public static func signals(for episode: Episode, daysSeen: Int = 1,
                               neighbours: Int = 0, markedByHand: Bool = false) -> Signals {
        Signals(
            dwell: episode.duration,
            daysSeen: daysSeen,
            copiedFrom: episode.signals.contains { $0.kind == .clip },
            neighbours: neighbours,
            markedByHand: markedByHand
        )
    }
}
