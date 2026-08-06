import Foundation

/// Everything that happened, assembled into what the brain will actually remember.
///
/// Wave two shipped as six files of pure logic that nothing called: episodes could be built,
/// entities could be folded, relevance could be scored, and none of it ran. Each piece was tested
/// in isolation and the product had exactly the same memory as before. This is the file that joins
/// them, and joining them is where the real decisions live — the order the passes run in, what
/// counts as one moment, and what silently never gets remembered.
///
/// The pipeline, in one line: raw signals → episodes → relevance → entities → what gets indexed.
///
/// Two rules run underneath all of it and both are enforced here rather than at each call site,
/// because a privacy rule that every caller has to remember is a privacy rule that one caller will
/// forget. Nothing excluded enters, at any stage. And with capture paused nothing is assembled at
/// all — not filtered afterwards, not built and discarded: the pass returns empty before it reads
/// a single signal.
public struct Corpus: Sendable, Equatable {

    /// One episode and the reasoning about whether it was worth keeping.
    ///
    /// The verdict travels with the episode instead of being recomputed for the graph view. A
    /// person looking at their own brain asking why something they clearly remember is missing
    /// deserves the actual numbers that decided it, not a second guess made later from different
    /// inputs that might not even agree.
    public struct Considered: Sendable, Equatable, Identifiable {
        public let episode: Episode
        public let signals: Relevance.Signals
        public let score: Double
        public let isIndexed: Bool
        /// Why, in words a person can act on.
        public let why: String

        public var id: String { episode.id }

        public init(episode: Episode, signals: Relevance.Signals, score: Double,
                    isIndexed: Bool, why: String) {
            self.episode = episode
            self.signals = signals
            self.score = score
            self.isIndexed = isIndexed
            self.why = why
        }
    }

    /// Every episode built, including the ones that were not worth indexing.
    public let episodes: [Episode]
    /// The verdict on each, in the same order.
    public let considered: [Considered]
    /// Who and what turned up, folded into canonical names.
    public let entities: [Entity]
    /// Merges that need a person to say yes. Never applied on their own.
    public let proposals: [MergeProposal]
    /// What the index should be given.
    public let items: [Indexer.Item]
    /// True when capture was paused and nothing was assembled.
    public let isPaused: Bool

    public init(episodes: [Episode] = [], considered: [Considered] = [], entities: [Entity] = [],
                proposals: [MergeProposal] = [], items: [Indexer.Item] = [], isPaused: Bool = false) {
        self.episodes = episodes
        self.considered = considered
        self.entities = entities
        self.proposals = proposals
        self.items = items
        self.isPaused = isPaused
    }

    public var indexed: [Episode] { considered.filter(\.isIndexed).map(\.episode) }

    public static let empty = Corpus()
    public static let paused = Corpus(isPaused: true)
}

// MARK: - The sources that have no type of their own yet

/// A page that was open, from a browser's own history database.
///
/// Deliberately not a full page fetch. What answers "qué estaba mirando cuando decidí esto" is the
/// title and the moment, and re-fetching the page later would both leave the machine and return
/// something that is no longer what was read.
public struct BrowserVisit: Sendable, Equatable {
    public let at: Date
    public let url: String
    public let title: String
    /// Which browser it came from, so a person can tell where their own history is being read.
    public let browser: String

    public init(at: Date, url: String, title: String, browser: String) {
        self.at = at
        self.url = url
        self.title = title
        self.browser = browser
    }

    /// The part of a URL worth treating as one subject.
    ///
    /// Host alone collapses every page of `github.com` into a single thing, which makes days-seen
    /// meaningless; the full URL never repeats, which makes it meaningless the other way. Host plus
    /// the first path segment is the level at which a person actually returns to something.
    public var subject: String {
        guard let components = URLComponents(string: url), let host = components.host else {
            return url
        }
        let clean = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let first = components.path.split(separator: "/").first.map(String.init)
        return first.map { clean + "/" + $0 } ?? clean
    }
}

/// Words that were said out loud, once something turned them into text.
public struct Transcript: Sendable, Equatable {
    public let at: Date
    public let title: String
    public let text: String
    /// The recording it came from, kept so a statement can be traced back to the audio.
    public let sourcePath: String

    public init(at: Date, title: String, text: String, sourcePath: String) {
        self.at = at
        self.title = title
        self.text = text
        self.sourcePath = sourcePath
    }
}

// MARK: - Assembly

public enum CorpusBuilder {

    /// Everything the assembly reads. Values, so a pass can be run over a fixed day in a test and
    /// produce exactly the same corpus every time.
    public struct Input: Sendable {
        public var nodes: [WorkNode]
        public var clips: [Clip]
        public var exchanges: [Conversations.Exchange]
        public var visits: [BrowserVisit]
        public var transcripts: [Transcript]
        /// Stretches of time the person asked to forget. Nothing from inside them comes back.
        public var forgotten: [Privacy.Period]
        public var privacy: Privacy.State
        public var excludedApps: Set<String>
        public var excludedDomains: Set<String>
        /// Merge questions already answered with a no. Never asked twice.
        public var rejectedMerges: Set<String>
        /// Subjects a person pinned or saved by hand. Ends the relevance argument for their episodes.
        public var markedByHand: Set<String>
        public var now: Date
        public var calendar: Calendar

        public init(nodes: [WorkNode] = [], clips: [Clip] = [],
                    exchanges: [Conversations.Exchange] = [], visits: [BrowserVisit] = [],
                    transcripts: [Transcript] = [], forgotten: [Privacy.Period] = [],
                    privacy: Privacy.State = Privacy.State(),
                    excludedApps: Set<String> = [], excludedDomains: Set<String> = [],
                    rejectedMerges: Set<String> = [], markedByHand: Set<String> = [],
                    now: Date = .now, calendar: Calendar = .current) {
            self.nodes = nodes
            self.clips = clips
            self.exchanges = exchanges
            self.visits = visits
            self.transcripts = transcripts
            self.forgotten = forgotten
            self.privacy = privacy
            self.excludedApps = excludedApps
            self.excludedDomains = excludedDomains
            self.rejectedMerges = rejectedMerges
            self.markedByHand = markedByHand
            self.now = now
            self.calendar = calendar
        }
    }

    /// Beyond this many entities the pairwise merge check stops being worth its cost.
    ///
    /// The check is quadratic and the entities are sorted by weight, so the cap keeps the ones that
    /// actually recur. Comparing the four-thousandth incidental name against the others finds
    /// nothing and costs the most.
    public static let entityLimit = 400

    /// The whole pass.
    public static func assemble(_ input: Input) -> Corpus {
        // First, before anything is read. A paused brain that still assembles and then discards is
        // a brain that had the data in memory, and "we built it but threw it away" is not what
        // anybody means when they pause capture.
        guard input.privacy.isCapturing(at: input.now) else { return .paused }

        let signals = allSignals(input)
        let episodes = EpisodeBuilder.episodes(from: signals, now: input.now)
            .filter { episode in !input.forgotten.contains { $0.contains(episode.start) } }

        let considered = weigh(episodes, input: input)
        let entities = fold(episodes: episodes, nodes: allowedNodes(input), input: input)

        var items = considered.filter(\.isIndexed).map { item(for: $0.episode) }
        items += Conversations.items(from: allowedExchanges(input))
            .filter { !SecretGuard.carriesSecret($0.text) }
        // The assistant's answer and the transcript both go through the guard, not just the
        // question and the clip. An assistant printing a key inside a curl command is the normal
        // case, not the rare one, and a measured probe confirmed both walked straight in.
        items += allowedTranscripts(input).map(item(for:))

        // The last gate, applied to everything rather than to each source. Sources are re-read on
        // every pass and identifiers are derived from content, so a rebuild is exact: without this
        // the afternoon somebody forgot came back within the half hour, and the app had said "para
        // siempre" while it happened.
        let remembered = items.filter { item in
            !input.forgotten.contains { $0.contains(item.occurredAt) }
        }
        return Corpus(episodes: episodes, considered: considered, entities: entities.entities,
                      proposals: entities.proposals, items: remembered, isPaused: false)
    }

    // MARK: - Signals

    public static func allSignals(_ input: Input) -> [Episode.Signal] {
        guard input.privacy.isCapturing(at: input.now) else { return [] }
        return signals(fromNodes: allowedNodes(input))
            + signals(fromClips: allowedClips(input))
            + signals(fromExchanges: allowedExchanges(input))
            + signals(fromVisits: allowedVisits(input))
            + signals(fromTranscripts: allowedTranscripts(input))
    }

    /// Nodes that describe a moment rather than a concept.
    ///
    /// People, companies and projects are left out on purpose. They are not things that happened at
    /// a time — they are what the things that happened were *about*, and feeding them in as signals
    /// would stretch every episode to cover the whole life of the project node it touched. They
    /// reach the corpus through the entity layer instead, which is where they belong.
    public static func signals(fromNodes nodes: [WorkNode]) -> [Episode.Signal] {
        nodes.compactMap { node in
            guard let kind = signalKind(for: node.kind) else { return nil }
            let subject = node.target.isEmpty ? node.id : node.target
            return Episode.Signal(at: node.lastSeen, kind: kind, subject: subject, title: node.name)
        }
    }

    static func signalKind(for kind: WorkNode.Kind) -> Episode.Signal.Kind? {
        switch kind {
        case .file: .file
        case .application: .application
        case .meeting: .meeting
        case .conversation: .conversation
        case .decision, .commitment: .note
        case .person, .company, .project: nil
        }
    }

    /// A copy is attributed to the app it came out of, so copies cluster with the work that
    /// produced them instead of forming an episode of their own made entirely of clipboard.
    public static func signals(fromClips clips: [Clip]) -> [Episode.Signal] {
        clips.map { clip in
            let subject = clip.sourceApp.isEmpty ? "portapapeles" : clip.sourceApp
            let title = String(clip.text.prefix(60))
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return Episode.Signal(at: clip.createdAt, kind: .clip, subject: subject,
                                  title: title.isEmpty ? "Copia" : title)
        }
    }

    /// The working directory is the subject, not the question. That is what ties a conversation to
    /// the project it was about, and it is the only field in an exchange that is stable across the
    /// dozens of questions asked inside one piece of work.
    public static func signals(fromExchanges exchanges: [Conversations.Exchange]) -> [Episode.Signal] {
        exchanges.map { exchange in
            let subject = exchange.workingDirectory.isEmpty ? L("conversation") : exchange.workingDirectory
            let title = String(exchange.asked.prefix(70)).replacingOccurrences(of: "\n", with: " ")
            return Episode.Signal(at: exchange.at, kind: .conversation, subject: subject, title: title)
        }
    }

    /// A page that was read is filed as a document, because that is what it is to the person who
    /// read it. `Episode.Signal.Kind` has no web case and adding one would touch the episode model
    /// that the rest of wave two is already tested against; a page is closer to a file than to
    /// anything else on that list, and unlike `.application` it counts as work.
    public static func signals(fromVisits visits: [BrowserVisit]) -> [Episode.Signal] {
        visits.compactMap { visit in
            let title = visit.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return Episode.Signal(at: visit.at, kind: .file, subject: visit.subject, title: title)
        }
    }

    public static func signals(fromTranscripts transcripts: [Transcript]) -> [Episode.Signal] {
        transcripts.map {
            Episode.Signal(at: $0.at, kind: .meeting, subject: $0.sourcePath, title: $0.title)
        }
    }

    // MARK: - Exclusions

    /// A node is off limits when the app it belongs to is, or when whatever it points at is.
    ///
    /// Both fields are offered to `isExcluded` rather than only the obvious one: a file node whose
    /// target is a URL is still a URL, and a rule that only checked application nodes would let a
    /// bank page through as a "file" without anybody noticing.
    public static func allowedNodes(_ input: Input) -> [WorkNode] {
        input.nodes.filter { node in
            !Privacy.isExcluded(bundleIdentifier: node.kind == .application ? node.target : nil,
                                url: node.target.isEmpty ? node.name : node.target,
                                apps: input.excludedApps, domains: input.excludedDomains)
        }
    }

    public static func allowedClips(_ input: Input) -> [Clip] {
        input.clips.filter { clip in
            guard !Privacy.isExcluded(bundleIdentifier: clip.sourceApp, url: clip.text,
                                      apps: input.excludedApps, domains: input.excludedDomains)
            else { return false }
            // Anything the guard would refuse to keep never becomes a signal either. A password is
            // still a password when it is only a title inside an episode.
            return !SecretGuard.carriesSecret(clip.text)
        }
    }

    /// Transcripts pass the same two gates as everything else: the exclusion list and the
    /// credential guard. They used to pass neither, which made spoken audio the only source that
    /// could carry a key into the index untouched.
    public static func allowedTranscripts(_ input: Input) -> [Transcript] {
        input.transcripts.filter { !SecretGuard.carriesSecret($0.text) }
    }

    public static func allowedExchanges(_ input: Input) -> [Conversations.Exchange] {
        input.exchanges.filter { exchange in
            !Privacy.isExcluded(bundleIdentifier: nil, url: exchange.workingDirectory,
                                apps: input.excludedApps, domains: input.excludedDomains)
                && !SecretGuard.carriesSecret(exchange.asked)
                && !isMachineWritten(exchange.asked)
        }
    }

    /// Wrappers the harness writes into the session as if a person had typed them.
    ///
    /// Found by running this pass over a real `~/.claude/projects`: the second "question" indexed
    /// was `<task-notification><task-id>a25e62fe…`, which is plumbing talking to itself. These
    /// arrive as user rows and carry no tool-result block, so the conversation reader cannot see
    /// what they are — but they are long enough to clear the minimum length and numerous enough to
    /// crowd out real questions in any search for one's own words.
    public static let machineMarkers = [
        "<task-notification", "<system-reminder", "<command-name", "<command-message",
        "<local-command-stdout", "<local-command-stderr", "<user-prompt-submit-hook",
    ]

    public static func isMachineWritten(_ text: String) -> Bool {
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60).lowercased()
        return machineMarkers.contains { head.contains($0) }
    }

    public static func allowedVisits(_ input: Input) -> [BrowserVisit] {
        input.visits.filter { visit in
            !Privacy.isExcluded(bundleIdentifier: nil, url: visit.url,
                                apps: input.excludedApps, domains: input.excludedDomains)
        }
    }

    // MARK: - Relevance

    /// Scores every episode, with the two signals that can only be seen across the whole day.
    ///
    /// `daysSeen` and `neighbours` are why this cannot live inside `Relevance`: both are properties
    /// of an episode's place among the others, and an episode scored alone can never know it is the
    /// fourth time this week.
    public static func weigh(_ episodes: [Episode], input: Input) -> [Corpus.Considered] {
        let days = daysPerSubject(episodes, calendar: input.calendar)

        return episodes.map { episode in
            let seen = episode.subjects.map { days[$0]?.count ?? 1 }.max() ?? 1
            // Distinct things touched alongside each other, not the count of signals: forty saves
            // of the same file is one piece of work, not forty companions.
            let neighbours = max(0, episode.subjects.count - 1)
            let byHand = episode.subjects.contains { input.markedByHand.contains($0) }

            let signals = Relevance.signals(for: episode, daysSeen: seen,
                                            neighbours: neighbours, markedByHand: byHand)
            let score = Relevance.score(signals)
            // An episode that has not settled is never indexed, however well it scores. Indexing
            // one still in progress writes a passage that is wrong within the hour, and anything
            // that cited it in the meantime cited half a story.
            let settled = EpisodeBuilder.isSettled(episode, now: input.now)
            let worth = Relevance.isWorthIndexing(signals)
            let why = settled ? Relevance.explain(signals) : L("It is still going on; it gets indexed when it ends.")

            return Corpus.Considered(episode: episode, signals: signals, score: score,
                                     isIndexed: settled && worth, why: why)
        }
    }

    /// Which distinct days each subject was touched on.
    static func daysPerSubject(_ episodes: [Episode], calendar: Calendar) -> [String: Set<Date>] {
        var result: [String: Set<Date>] = [:]
        for episode in episodes {
            let day = calendar.startOfDay(for: episode.start)
            for subject in Set(episode.subjects) {
                result[subject, default: []].insert(day)
            }
        }
        return result
    }

    // MARK: - Entities

    /// Folds every name that turned up into canonical entities, and asks about the rest.
    public static func fold(episodes: [Episode], nodes: [WorkNode],
                            input: Input) -> (entities: [Entity], proposals: [MergeProposal]) {
        var counts: [String: Entity] = [:]

        func add(_ entity: Entity) {
            guard !Identity.isGeneric(entity.canonical) else { return }
            if let existing = counts[entity.id] {
                counts[entity.id] = Entity(id: existing.id, kind: existing.kind,
                                           canonical: existing.canonical,
                                           aliases: existing.aliases.union(entity.aliases),
                                           weight: existing.weight + entity.weight)
            } else {
                counts[entity.id] = entity
            }
        }

        // Concept nodes are entities directly; nothing has to be inferred from them.
        for node in nodes {
            switch node.kind {
            case .person: add(Entity(kind: .person, canonical: node.name))
            case .company: add(Entity(kind: .company, canonical: node.name))
            case .project:
                if !Identity.isPassingThrough(node.name) {
                    add(Entity(kind: .project, canonical: node.name))
                }
            default: break
            }
        }

        // Everything else has to be read out of what the signals point at. Iterating signals rather
        // than bare subjects is what makes the next line possible: the same string means different
        // things depending on which source produced it.
        for episode in episodes {
            for signal in episode.signals {
                let subject = signal.subject
                if subject.contains("/"), let project = Identity.project(fromPath: path(for: signal)) {
                    // Somewhere you passed through is not something you work on. Without this the
                    // graph fills with google.com and instagram.com, and the real projects are
                    // three dots lost among twenty. Not a `continue`: the same signal may still
                    // carry an address worth reading.
                    if !Identity.isPassingThrough(project) {
                        add(Entity(kind: .project, canonical: project))
                    }
                }
                if subject.contains("@"), let company = Identity.company(fromEmail: subject) {
                    add(Entity(kind: .company, canonical: company))
                }
            }
        }

        let ranked = counts.values
            .sorted { $0.weight == $1.weight ? $0.id < $1.id : $0.weight > $1.weight }
            .prefix(entityLimit)

        return resolve(Array(ranked), episodes: episodes, rejected: input.rejectedMerges)
    }

    /// A signal's subject as `Identity.project(fromPath:)` expects to receive it.
    ///
    /// That function drops the last component because it is written for file paths, where the last
    /// component is a filename. A conversation's subject is a *working directory*, so the last
    /// component is the project itself — and dropping it names the parent instead. Measured against
    /// a real session folder: every conversation under `.../worktrees/belauncher` was filed as the
    /// project "worktrees", which is a container shared by every worktree on the machine and would
    /// have merged unrelated work into one heap.
    static func path(for signal: Episode.Signal) -> String {
        switch signal.kind {
        case .conversation: signal.subject + "/·"
        default: signal.subject
        }
    }

    /// Applies the merges that are certain and collects the questions for the ones that are not.
    static func resolve(_ entities: [Entity], episodes: [Episode],
                        rejected: Set<String>) -> (entities: [Entity], proposals: [MergeProposal]) {
        let together = coOccurrence(entities, episodes: episodes)
        var surviving = entities
        var proposals: [MergeProposal] = []
        var merged = Set<String>()

        var left = 0
        while left < surviving.count {
            if merged.contains(surviving[left].id) { left += 1; continue }
            var right = left + 1
            while right < surviving.count {
                if merged.contains(surviving[right].id) { right += 1; continue }
                let a = surviving[left], b = surviving[right]
                let pair = [a.id, b.id].sorted().joined(separator: "≡")
                switch Identity.decide(a, b, together: together[pair] ?? 0, rejected: rejected) {
                case .merge:
                    surviving[left] = Identity.merge(a, b)
                    merged.insert(b.id)
                case .ask(let proposal):
                    proposals.append(proposal)
                case .leaveAlone:
                    break
                }
                right += 1
            }
            left += 1
        }

        return (surviving.filter { !merged.contains($0.id) }, proposals)
    }

    /// How often two entities turn up in the same episode.
    static func coOccurrence(_ entities: [Entity], episodes: [Episode]) -> [String: Int] {
        var result: [String: Int] = [:]
        for episode in episodes {
            let text = episode.subjects.joined(separator: " ") + " "
                + episode.signals.map(\.title).joined(separator: " ")
            let folded = Identity.fold(text)
            let present = entities.filter { entity in
                entity.forms.contains { !$0.isEmpty && folded.contains($0) }
            }
            guard present.count > 1 else { continue }
            for i in present.indices {
                for j in present.index(after: i)..<present.endIndex {
                    let pair = [present[i].id, present[j].id].sorted().joined(separator: "≡")
                    result[pair, default: 0] += 1
                }
            }
        }
        return result
    }

    // MARK: - What the index is given

    /// An episode as a passage.
    ///
    /// Only what is on record: how long, when, and the names of the things touched. No summary is
    /// attempted here — guessing what a stretch of work *meant* from a list of filenames produces
    /// confident nonsense, and the nightly distillation exists precisely so that the guessing
    /// happens once, with a model, against a prompt that forces a citation.
    public static func item(for episode: Episode) -> Indexer.Item {
        let minutes = max(1, Int(episode.duration / 60))
        let when = DateFormatter.retrievalStamp().string(from: episode.start)

        var seen = Set<String>()
        let touched = episode.signals
            .filter { $0.kind.describesWork }
            .map(\.title)
            .filter { seen.insert($0).inserted }

        // Signals, not subjects, for the same reason `fold` uses them: a conversation's subject is a
        // directory and naming its parent would file the passage under the wrong project.
        var projects = Set<String>()
        for signal in episode.signals where signal.subject.contains("/") {
            if let project = Identity.project(fromPath: path(for: signal)) { projects.insert(project) }
        }

        var text = "\(episode.title)\n\n\(when), \(minutes) min.\n" + touched.joined(separator: "\n")
        if !projects.isEmpty {
            text += "\n\nProyecto: " + projects.sorted().joined(separator: ", ")
        }

        // Indexed as a work node: `IndexedSource.Kind` has no episode case, and of the kinds it
        // does have this is the one that means "captured from what happened" rather than "typed by
        // a person", which is what an episode is.
        return Indexer.Item(source: IndexedSource(kind: .node, id: episode.id),
                            title: episode.title.isEmpty ? episode.fallbackTitle : episode.title,
                            text: text, occurredAt: episode.start)
    }

    public static func item(for transcript: Transcript) -> Indexer.Item {
        Indexer.Item(
            source: IndexedSource(kind: .conversation,
                                  id: "audio:" + Semantic.digest(transcript.sourcePath).prefix(16)),
            title: transcript.title,
            text: transcript.title + "\n\n" + transcript.text,
            occurredAt: transcript.at
        )
    }
}
