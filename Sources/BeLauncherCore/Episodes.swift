import Foundation

/// What you were doing, as a stretch of time rather than a list of events.
///
/// Nobody asks what they did at 14:32. They ask *how did I solve the auth thing*, and the answer
/// is two hours moving between three files, four tabs and a conversation, none of which means
/// anything alone. Stored as forty separate rows that question has no answer: each row is true and
/// useless, and a search over them returns whichever row happens to share the most words.
///
/// An episode is the unit that can be titled, ranked, cited and forgotten as one thing. The raw
/// signals stay on disk — they are the evidence — but the episode is what gets indexed.
public struct Episode: Sendable, Equatable, Identifiable {

    /// One thing that happened, flattened from wherever it came from.
    public struct Signal: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable, CaseIterable {
            case file
            case application
            case meeting
            case conversation
            case clip
            case note

            /// Whether this kind, on its own, says anything about *what* you were doing.
            ///
            /// Bringing an app to the front is the weakest signal there is — a launcher, a
            /// terminal and a browser get focused a hundred times a day between real pieces of
            /// work — so an episode made only of those is a record of switching, not of working.
            public var describesWork: Bool { self != .application }
        }

        public let at: Date
        public let kind: Kind
        /// Stable identity of the thing touched: a node id, a path, an entity key.
        public let subject: String
        public let title: String

        public init(at: Date, kind: Kind, subject: String, title: String) {
            self.at = at
            self.kind = kind
            self.subject = subject
            self.title = title
        }
    }

    public let id: String
    public let start: Date
    public let end: Date
    public let signals: [Signal]
    /// Written later, from the contents. Empty until something titles it.
    public var title: String

    public init(id: String, start: Date, end: Date, signals: [Signal], title: String = "") {
        self.id = id
        self.start = start
        self.end = end
        self.signals = signals
        self.title = title
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Everything touched, most touched first. This is what links an episode into the graph.
    public var subjects: [String] {
        var counts: [String: Int] = [:]
        for signal in signals { counts[signal.subject, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
    }

    /// A line a person would recognise, used until something writes a better title.
    ///
    /// Deliberately not a summary. Guessing at meaning from filenames produces confident nonsense
    /// like "trabajo en index"; naming what was touched is boring and always true.
    public var fallbackTitle: String {
        let named = signals
            .filter { $0.kind.describesWork }
            .map(\.title)
        var seen = Set<String>()
        let unique = named.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return L("No title") }
        let head = unique.prefix(3).joined(separator: ", ")
        return unique.count > 3 ? head + L(" and %@ more", String(unique.count - 3)) : head
    }
}

public enum EpisodeBuilder {

    /// How long a pause has to be before it means you stopped.
    ///
    /// Twenty five minutes rather than five: a coffee, a phone call and reading something on paper
    /// all happen inside a single piece of work, and cutting there produces four episodes about
    /// the same thing — which is worse than one episode with a hole in it, because it fragments
    /// the very thing an episode exists to hold together.
    public static let idleGap: TimeInterval = 25 * 60

    /// Nothing runs for six hours on one subject. Past this it is a day, not an episode, and a
    /// day retrieves badly: it matches everything and answers nothing.
    public static let maximumLength: TimeInterval = 4 * 60 * 60

    /// Below this it is an interruption, not work.
    public static let minimumLength: TimeInterval = 90

    /// An episode has to be about something. Two signals that share no subject and no time are
    /// two accidents next to each other.
    public static let minimumSignals = 2

    /// Groups signals into episodes.
    ///
    /// Only two rules, on purpose. Every extra heuristic here is a rule that fires wrongly on
    /// somebody's real day, and the failure is silent: you never see the episode that was cut in
    /// half, you just get a worse answer.
    public static func episodes(from signals: [Episode.Signal], now: Date = .now) -> [Episode] {
        let ordered = signals.sorted { $0.at < $1.at }
        guard !ordered.isEmpty else { return [] }

        var groups: [[Episode.Signal]] = []
        var current: [Episode.Signal] = []

        for signal in ordered {
            if let last = current.last {
                let gap = signal.at.timeIntervalSince(last.at)
                let span = signal.at.timeIntervalSince(current[0].at)
                if gap > idleGap || span > maximumLength {
                    groups.append(current)
                    current = []
                }
            }
            current.append(signal)
        }
        if !current.isEmpty { groups.append(current) }

        return groups.compactMap(episode(from:))
    }

    /// Turns a group into an episode, or refuses.
    ///
    /// Refusing matters as much as building. An index full of one-signal "episodes" recording
    /// that a browser came to the front dilutes every search: they are numerous, they are short,
    /// and they are about nothing.
    static func episode(from group: [Episode.Signal]) -> Episode? {
        guard group.count >= minimumSignals,
              let first = group.first, let last = group.last else { return nil }
        guard group.contains(where: { $0.kind.describesWork }) else { return nil }
        let length = last.at.timeIntervalSince(first.at)
        guard length >= minimumLength else { return nil }

        // The identifier is derived from when it started and what it is about, so re-running the
        // builder over the same signals produces the same episode instead of a duplicate with a
        // new id. Assembly runs repeatedly as new signals arrive; without this the index would
        // fill with copies.
        let seed = "\(Int(first.at.timeIntervalSince1970))|" + group.map(\.subject).sorted().joined(separator: ",")
        let episode = Episode(id: "episode:" + Semantic.digest(seed).prefix(16),
                              start: first.at, end: last.at, signals: group)
        return Episode(id: episode.id, start: episode.start, end: episode.end,
                       signals: group, title: episode.fallbackTitle)
    }

    /// The tail of the day that is still happening.
    ///
    /// An episode that has not ended yet must not be titled and indexed as finished: it would be
    /// written now, rewritten in ten minutes, and cited in between with half its content missing.
    public static func isSettled(_ episode: Episode, now: Date = .now) -> Bool {
        now.timeIntervalSince(episode.end) > idleGap
    }
}
