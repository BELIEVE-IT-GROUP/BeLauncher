import Foundation
import BeLauncherCore

/// The part that actually runs.
///
/// `Corpus` decides what the brain remembers and `CorpusRunner` is what calls it — on a schedule,
/// off the launch path, and never while capture is paused. Wave two was six files of correct logic
/// that no code path reached, so this file is the difference between a tested design and a product
/// that remembers anything at all.
///
/// Three constraints shape it, in order of how badly breaking them hurts:
///
/// 1. **Nothing blocks the launcher.** The hot key is the product. Copying a Safari history of tens
///    of megabytes and cutting a day into passages both take real time, so everything expensive
///    happens off the main actor and the first pass waits until well after the window is usable.
/// 2. **Every step re-reads the pause.** Checking once at the top and then working for forty
///    seconds means a person who pauses capture mid-pass still gets that pass written. The state is
///    read again before anything is stored.
/// 3. **Capture is off until somebody says otherwise.** `graph_enabled` has shipped `false` since
///    the beginning and the runner does not quietly change that; it is asked for, once, in words.
@MainActor
final class CorpusRunner {

    private let store: Store
    private weak var brain: BrainSearch?
    /// The local model, for the nightly pass. Injected so the runner never reaches into the app.
    private let ask: (String, String) async throws -> String

    private var loop: Task<Void, Never>?

    /// How often the corpus is rebuilt.
    ///
    /// Half an hour, not minutes: an episode needs a twenty-five minute gap to close, so a pass
    /// every five minutes would spend its time re-reading work that cannot have settled yet.
    static let interval: Duration = .seconds(30 * 60)

    /// How long after launch the first pass runs. Long enough for the hot key, the clipboard
    /// watcher and the first embedding pass to be in place.
    static let warmUp: Duration = .seconds(90)

    /// How far back each pass looks. A day of overlap, so a Mac that was asleep does not leave a
    /// hole and a pass that failed is simply redone by the next one.
    static let window: TimeInterval = 36 * 60 * 60

    init(store: Store, brain: BrainSearch?,
         ask: @escaping (String, String) async throws -> String) {
        self.store = store
        self.brain = brain
        self.ask = ask
    }

    // MARK: - Schedule

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: CorpusRunner.warmUp)
            while !Task.isCancelled {
                await self?.runOnce()
                try? await Task.sleep(for: CorpusRunner.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Whether the person has agreed to any of this. Everything is gated behind it.
    var isCapturing: Bool {
        store.setting("graph_enabled", default: false) && store.privacyState.isCapturing()
    }

    // MARK: - One pass

    func runOnce(now: Date = .now) async {
        guard isCapturing else { return }

        let since = now.addingTimeInterval(-CorpusRunner.window)
        let excludedApps = store.excludedFromCapture()
        let excludedDomains = store.excludedDomains()

        // Everything expensive off it: copying browser databases and walking session logs are both
        // file-system bound, and on the main actor they would be felt as a stuck launcher.
        let gathered = await Task.detached(priority: .utility) {
            let history = BrowserHistory.read(since: since, excludedDomains: excludedDomains,
                                              excludedApps: excludedApps)
            let exchanges = Self.conversations(since: since)
            return (history, exchanges)
        }.value

        let transcripts = await transcribePending(since: since)
        await refreshCorrections()

        let input = assemblyInput(now: now, visits: gathered.0.visits,
                                  exchanges: gathered.1, transcripts: transcripts)

        // The assembly is pure and the biggest single cost in the pass, so it runs off the main
        // actor too. Nothing it touches is shared.
        let corpus = await Task.detached(priority: .utility) {
            CorpusBuilder.assemble(input)
        }.value

        // Re-read rather than trusting the state captured at the top: a pass takes seconds and
        // somebody who hits pause during one means it, including for the work already done.
        guard isCapturing, !corpus.isPaused else { return }

        write(corpus)
        if !gathered.0.problems.isEmpty {
            store.setSetting("corpus_last_problem", gathered.0.problems.joined(separator: "\n"))
        }
        store.setSetting("corpus_last_run", String(now.timeIntervalSince1970))

        await distillIfDue(now: now)
    }

    /// Everything the assembly is told, gathered in one place so it can be read at a glance.
    ///
    /// It is a method rather than four lines inside `runOnce` because of what was missing from
    /// those four lines: `forgotten` was never filled in. `Store.forget` writes a ledger of the
    /// stretches somebody asked to erase, `CorpusBuilder` has a gate that reads it, and nothing
    /// connected the two — so an afternoon that was forgotten came back on the next pass, half an
    /// hour later, with its original timestamps. The browser's own history file and the session
    /// logs are re-read every pass and the identifiers are derived from their content, so the
    /// rebuild was exact: the app said "para siempre" and meant thirty minutes.
    ///
    /// The store is read here rather than passed in so that adding a source cannot quietly skip a
    /// privacy gate again: there is one place that answers what the builder is allowed to see.
    func assemblyInput(now: Date, visits: [BrowserVisit],
                       exchanges: [Conversations.Exchange],
                       transcripts: [Transcript]) -> CorpusBuilder.Input {
        let since = now.addingTimeInterval(-CorpusRunner.window)
        return CorpusBuilder.Input(
            nodes: store.nodes(limit: 2_000).filter { $0.lastSeen >= since },
            clips: store.clips(limit: 500).filter { $0.createdAt >= since },
            exchanges: exchanges, visits: visits, transcripts: transcripts,
            forgotten: store.forgottenPeriods(),
            privacy: store.privacyState,
            excludedApps: store.excludedFromCapture(), excludedDomains: store.excludedDomains(),
            rejectedMerges: rejectedMerges(), markedByHand: markedByHand(), now: now
        )
    }

    /// Writes what the corpus decided into the index and the graph.
    func write(_ corpus: Corpus) {
        var written = 0
        for item in corpus.items {
            written += store.replacePassages(for: item.source, title: item.title,
                                             occurredAt: item.occurredAt, text: item.text).count
        }
        // Kept so Ajustes can say how much of the brain came from watching rather than from typing.
        // A capture that is on and producing nothing looks identical to one that is off.
        store.setSetting("corpus_last_passages", String(written))

        // Entities become graph nodes so the existing graph view and the retriever's hop can reach
        // them. Nothing here invents edges: an entity that only appeared once is still a node, and
        // the edges come from the capture layer that already draws them.
        //
        // Except the ones somebody threw out of the graph. Deleting the row and then writing it
        // back half an hour later is the shape of every complaint about an app that will not let
        // go of something, and it is worse than never having offered to forget it.
        for entity in corpus.entities where entity.weight > 1 && !learned.hidden.contains(entity.id) {
            store.upsertNode(WorkNode(
                id: entity.id,
                kind: graphKind(for: entity.kind),
                name: entity.canonical,
                detail: entity.aliases.isEmpty
                    ? entity.kind.label
                    : entity.kind.label + L(" · also ") + entity.aliases.sorted().prefix(3).joined(separator: ", ")
            ))
        }

        // The edges. Without these the graph is not a graph: it opened with "23 nodos · 0
        // relaciones", a scatter of dots, because the corpus worked out every relationship and
        // then dropped it on the floor. Entities became rows, episodes were re-derived from the
        // wrong source, and nothing ever wrote what connects to what.
        //
        // Two kinds, and only two, because these are the ones the corpus actually knows:
        // an episode came out of the things it touched, and two things worked on inside the same
        // episode were worked on together.
        // Subjects have to be translated into entity ids before anything is linked. They are raw
        // signal identifiers — a path, a host, a node id — and the graph only keeps an edge when
        // both ends are nodes it knows. The first version linked the raw subject and the graph
        // dropped all 157 edges in silence, opening with "23 nodos · 0 relaciones": a scatter of
        // dots that looked exactly like a graph with nothing to say.
        var byForm: [String: String] = [:]
        for entity in corpus.entities {
            for form in entity.forms { byForm[form] = entity.id }
        }
        func nodeID(for subject: String) -> String? {
            if workNodeExists(subject) { return subject }
            // A path is about its project, a host is about itself, and both are folded the same
            // way the entity was when it was named.
            if let project = Identity.project(fromPath: subject),
               let id = byForm[Identity.fold(project)] { return id }
            return byForm[Identity.fold((subject as NSString).lastPathComponent)]
                ?? byForm[Identity.fold(subject)]
        }

        for episode in corpus.episodes where !learned.hidden.contains(episode.id) {
            let subjects = episode.subjects.prefix(8).compactMap(nodeID)
                .filter { !learned.hidden.contains($0) }
                .reduce(into: [String]()) { seen, id in if !seen.contains(id) { seen.append(id) } }
            store.upsertNode(WorkNode(id: episode.id, kind: .conversation, name: episode.title,
                                      detail: "Episodio · " + Self.when(episode.start),
                                      lastSeen: episode.start))
            for subject in subjects {
                store.link(WorkEdge(source: episode.id, target: subject, kind: .cameFrom,
                                    at: episode.start))
            }
            // Things touched inside the same stretch belong together. This is the edge that
            // answers "qué más estaba tocando cuando trabajé en esto".
            for (index, left) in subjects.enumerated() {
                for right in subjects.dropFirst(index + 1) {
                    store.link(WorkEdge(source: left, target: right, kind: .workedWith,
                                        at: episode.start))
                }
            }
        }

        // An alias is a name the same thing answers to, so the entity it belongs to owns it.
        for entity in corpus.entities where entity.weight > 1 && !learned.hidden.contains(entity.id) {
            for alias in entity.aliases.prefix(4) {
                let aliasID = WorkNode.identifier(kind: graphKind(for: entity.kind), name: alias)
                guard aliasID != entity.id else { continue }
                store.link(WorkEdge(source: aliasID, target: entity.id, kind: .partOf))
            }
        }

        // Questions are stored rather than asked here. A modal in the middle of somebody's
        // afternoon to ask whether two folder names are the same project is the fastest way to
        // teach them to dismiss anything this app ever asks.
        let questions = corpus.proposals.prefix(10).map { $0.id + "\u{1F}" + $0.question }
        store.setSetting("corpus_merge_questions", questions.joined(separator: "\n"))

        Task { @MainActor [weak self] in
            _ = try? await self?.brain?.embedEverything()
        }
    }

    /// Whether the subject is already a node the graph knows, which is the case for anything that
    /// came from the capture layer rather than from a file path or a URL.
    private func workNodeExists(_ id: String) -> Bool {
        store.node(id: id) != nil
    }

    static func when(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter.string(from: date)
    }

    private func graphKind(for kind: Entity.Kind) -> WorkNode.Kind {
        switch kind {
        case .person: .person
        case .company: .company
        case .project: .project
        case .topic: .project
        }
    }

    // MARK: - Conversations

    /// Reads the assistant sessions that changed inside the window.
    ///
    /// Filtered by modification date before a byte is read: these files reach tens of megabytes and
    /// there are hundreds of them, so reading them all every half hour would be the most expensive
    /// thing the app does, to re-derive exchanges it already has.
    nonisolated static func conversations(since: Date, limit: Int = 40) -> [Conversations.Exchange] {
        let root = Conversations.sessionsFolder()
        let fileManager = FileManager.default
        guard let walker = fileManager.enumerator(atPath: root) else { return [] }

        var recent: [(path: String, at: Date)] = []
        for case let entry as String in walker where entry.hasSuffix(".jsonl") {
            let path = (root as NSString).appendingPathComponent(entry)
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date, modified >= since
            else { continue }
            recent.append((path, modified))
        }

        return recent
            .sorted { $0.at > $1.at }
            .prefix(limit)
            .flatMap { file -> [Conversations.Exchange] in
                guard let text = try? String(contentsOfFile: file.path, encoding: .utf8) else { return [] }
                return Conversations.exchanges(inLines: text.components(separatedBy: .newlines))
            }
            .filter { $0.at >= since }
    }

    // MARK: - Audio

    /// Transcribes recordings dropped into the folder the person nominated.
    ///
    /// There is no recorder in this app and this does not add one. Turning on the microphone is a
    /// far bigger promise than reading a history file, and it is not one to make as a side effect
    /// of a capture setting. So the folder is opt-in, empty by default, and nothing is transcribed
    /// until somebody points at where their recordings already land.
    private func transcribePending(since: Date) async -> [Transcript] {
        let folder = store.setting("transcription_folder") ?? ""
        guard !folder.isEmpty, Transcription.isSupported else { return [] }

        let language = store.setting("transcription_language")
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: folder) else { return [] }

        let audio = ["m4a", "mp3", "wav", "aiff", "caf", "mp4", "mov"]
        var done = Set((store.setting("transcribed_files") ?? "").split(separator: "\n").map(String.init))
        var result: [Transcript] = []

        for entry in entries.sorted() where audio.contains((entry as NSString).pathExtension.lowercased()) {
            let path = (folder as NSString).appendingPathComponent(entry)
            guard !done.contains(path) else { continue }
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date, modified >= since
            else { continue }
            guard isCapturing else { break }

            do {
                result.append(try await Transcription.transcribe(
                    fileAt: URL(fileURLWithPath: path), spokenLanguage: language))
                done.insert(path)
            } catch {
                // Remembered as done even when it failed, so a file the model cannot handle is not
                // retried every half hour forever. The reason is kept where settings can show it.
                done.insert(path)
                store.setSetting("transcription_last_problem",
                                 entry + ": " + error.localizedDescription)
            }
            // One per pass. Transcription is fast but a folder of fifty recordings on the first run
            // would keep a core busy for a minute with no warning.
            break
        }

        store.setSetting("transcribed_files", done.sorted().suffix(500).joined(separator: "\n"))
        return result
    }

    // MARK: - The nightly pass

    /// Whether yesterday still needs distilling, and doing it if so.
    ///
    /// Gated on the hour as well as the day: distilling "yesterday" at nine in the morning while
    /// somebody is working means the model competes with them for the machine. Three in the morning
    /// on a Mac that is awake, or the first pass after it wakes up, is soon enough.
    func distillIfDue(now: Date = .now, calendar: Calendar = .current) async {
        guard isCapturing else { return }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        else { return }

        let last = Double(store.setting("distilled_day") ?? "") ?? 0
        guard last < yesterday.timeIntervalSince1970 else { return }
        guard calendar.component(.hour, from: now) >= 3 else { return }

        let day = Privacy.Period(from: yesterday, to: calendar.startOfDay(for: now))
        let input = CorpusBuilder.Input(
            nodes: store.nodes(limit: 2_000).filter { day.contains($0.lastSeen) },
            clips: store.clips(limit: 500).filter { day.contains($0.createdAt) },
            exchanges: Self.conversations(since: yesterday).filter { day.contains($0.at) },
            // The same gate as the half-hourly pass, and it matters more here: this pass hands what
            // it finds to a model and stores the summary as a note that outlives its sources. A
            // forgotten afternoon distilled into a statement is forgetting undone in writing.
            forgotten: store.forgottenPeriods(),
            privacy: store.privacyState,
            excludedApps: store.excludedFromCapture(), excludedDomains: store.excludedDomains(),
            now: now
        )
        let corpus = CorpusBuilder.assemble(input)
        let episodes = Distillation.ready(corpus.episodes, now: now) { episode in
            corpus.considered.first { $0.episode.id == episode.id }?.isIndexed ?? false
        }

        // Marked as done even with nothing to distill. A quiet day has no statements and retrying
        // it every half hour forever would ask the model to summarise nothing, repeatedly.
        store.setSetting("distilled_day", String(yesterday.timeIntervalSince1970))
        guard episodes.count >= Distillation.minimumEpisodes else { return }

        let (system, user) = Distillation.prompt(for: episodes)
        guard let answer = try? await ask(system, user) else { return }

        let statements = Distillation.parse(answer, episodes: episodes, day: yesterday)
        guard isCapturing else { return }

        for statement in statements {
            // The citation travels into the text itself. A statement whose sources are only in a
            // column is a statement that reads as fact the moment it is retrieved, and the whole
            // point of refusing uncited lines is lost if the citation does not survive storage.
            let cited = statement.text + L("\n\nComes from: ") + statement.sources.joined(separator: ", ")
            _ = store.replacePassages(for: IndexedSource(kind: .note, id: statement.id),
                                      title: statement.text, occurredAt: statement.day, text: cited)
        }
        _ = try? await brain?.embedEverything()
    }

    // MARK: - What the person corrected

    /// The corrections read off the corpus folder, kept between passes.
    private(set) var learned = CorpusFiles.Learned()

    /// Re-reads them, off the main actor.
    ///
    /// Off it because this parses every file in the corpus, and the reason the whole pass lives out
    /// here is that nothing in it may be felt as a stuck hot key.
    ///
    /// The folder is where the corrections are, and it is the only place they are. A mirror of them
    /// in the database would be a second truth about whether two entities are the same thing, and
    /// settling that is what the folder is for.
    func refreshCorrections(root: String = CorpusFolder.defaultRoot()) async {
        learned = await Task.detached(priority: .utility) {
            CorpusFiles.learned(inFolderAt: root)
        }.value
    }

    /// Merges already answered no.
    ///
    /// This read `corpus_rejected_merges` and nothing else, a setting no code in the app ever
    /// wrote, while the graph wrote the refusal into the front matter of the entity's file.
    /// Measured with the refusal on disk: the same pair was proposed again on the next pass, so
    /// the promise `Identity.decide` documents — «un rechazo se recuerda para siempre; volver a
    /// preguntar convierte enseñar en discutir» — was never kept. The setting is still read so an
    /// answer stored by an older build is not thrown away.
    private func rejectedMerges() -> Set<String> {
        learned.rejectedMerges.union((store.setting("corpus_rejected_merges") ?? "")
            .split(whereSeparator: \.isNewline).map(String.init))
    }

    /// Subjects the person kept by hand. A pinned clip says this mattered louder than any
    /// behavioural signal can, which is exactly what `markedByHand` is for — and so does marking
    /// something important in the graph, which wrote `pinned: true` into a file that nothing on
    /// this side read. `Relevance.score` hands a marked subject the top score and had never once
    /// been given one.
    private func markedByHand() -> Set<String> {
        learned.markedByHand.union(
            store.clips(limit: 500).filter(\.isPinned).map(\.sourceApp).filter { !$0.isEmpty })
    }
}
