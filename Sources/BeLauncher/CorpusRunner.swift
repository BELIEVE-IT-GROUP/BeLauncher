import Foundation
import IOKit.ps
import BeLauncherCore

struct CorpusRunRecord: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let startedAt: Date
    let finishedAt: Date
    let source: String?
    let phase: String
    let written: Int
    let problem: String?

    var duration: TimeInterval { max(0, finishedAt.timeIntervalSince(startedAt)) }
}

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
@Observable
final class CorpusRunner {
    enum RunResult: Equatable {
        case completed(written: Int)
        case paused
        case deferred(String)
        case busy
        case failed(String)
    }

    enum Phase: String, Equatable {
        case idle, waiting, gathering, assembling, writing, completed, paused, deferred, failed
    }

    private let store: Store
    private weak var brain: BrainSearch?
    private let corpusRoot: String
    /// The local model, for the nightly pass. Injected so the runner never reaches into the app.
    private let ask: (String, String) async throws -> String

    private var loop: Task<Void, Never>?
    private(set) var phase: Phase = .idle
    private(set) var isRunning = false
    private(set) var lastRun: Date?
    private(set) var lastWritten = 0
    private(set) var lastProblem: String?
    private(set) var lastDeferral: BackgroundRunPolicy.Reason?
    private(set) var runHistory: [CorpusRunRecord] = []
    private var checkpoint: IngestionCheckpoint?
    private var currentRunID = UUID().uuidString
    private var currentRunSource = "corpus"

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

    init(store: Store, brain: BrainSearch?, corpusRoot: String = CorpusFolder.defaultRoot(),
         ask: @escaping (String, String) async throws -> String) {
        self.store = store
        self.brain = brain
        self.corpusRoot = corpusRoot
        self.ask = ask
        if let raw = store.setting("corpus_checkpoint"),
           let data = raw.data(using: .utf8),
           let saved = try? JSONDecoder().decode(IngestionCheckpoint.self, from: data),
           !saved.completed {
            checkpoint = saved
        }
        if let raw = store.setting("corpus_run_history"),
           let data = raw.data(using: .utf8),
           let saved = try? JSONDecoder().decode([CorpusRunRecord].self, from: data) {
            runHistory = saved
        }
    }

    // MARK: - Schedule

    func start() {
        guard loop == nil else { return }
        setPhase(.waiting)
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
        setPhase(.idle)
    }

    /// Whether the person has agreed to any of this. Everything is gated behind it.
    var isCapturing: Bool {
        store.setting("graph_enabled", default: false) && store.privacyState.isCapturing()
    }

    // MARK: - One pass

    /// Runs the normal bounded pass, or only one connector when a person asks for an immediate
    /// refresh from Settings. The latter is important: "sync Mail" must not unexpectedly wake up
    /// every browser and conversation database on the Mac.
    func runOnce(source: String? = nil, now: Date = .now,
                 ignoringPowerPolicy: Bool = false) async -> RunResult {
        guard !isRunning else { return .busy }
        guard isCapturing else {
            setPhase(.paused)
            persistIngestionProgress(phase: .paused, source: source ?? currentRunSource)
            return .paused
        }
        if source == nil && !ignoringPowerPolicy {
            let thermal = BackgroundRunPolicy.ThermalState(
                rawValue: ProcessInfo.processInfo.thermalState.rawValue) ?? .nominal
            let power = Self.powerSource()
            switch BackgroundRunPolicy.decide(
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalState: thermal,
                onBattery: power.onBattery,
                batteryFraction: power.fraction
            ) {
            case .allowed:
                lastDeferral = nil
            case .deferred(let reason):
                lastDeferral = reason
                store.setSetting("corpus_last_deferral", reason.rawValue)
                setPhase(.deferred)
                persistIngestionProgress(phase: .deferred, source: source ?? "corpus")
                return .deferred(reason.rawValue)
            }
        }

        isRunning = true
        defer { isRunning = false }
        let startedAt = Date.now
        lastWritten = 0
        lastProblem = nil

        let runSource = source ?? "corpus"
        // A restart replays the same bounded overlap. The writes are replacements, so this is
        // idempotent and avoids losing the tail of a pass that was interrupted mid-write.
        let resumable = checkpoint.flatMap {
            $0.canResume(source: runSource) ? $0 : nil
        }
        currentRunID = resumable?.id ?? UUID().uuidString
        currentRunSource = runSource
        setPhase(.gathering, source: runSource)
        let replayFloor = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let since = max(resumable?.windowStart ?? now.addingTimeInterval(-CorpusRunner.window),
                        replayFloor)
        persistIngestionProgress(phase: .gathering, source: runSource)
        persistCheckpoint(source: runSource, phase: .gathering, windowStart: since)
        let excludedApps = store.excludedFromCapture()
        let excludedDomains = store.excludedDomains()
        let requestedSource = source ?? (ignoringPowerPolicy ? "all" : nil)
        let browsersEnabled = (source == nil || source == "browsers") &&
            sourceMayRun("browsers", requested: requestedSource) &&
            store.setting("source_enabled_browsers", default: true)
        let conversationsEnabled = (source == nil || source == "conversations") &&
            sourceMayRun("conversations", requested: requestedSource) &&
            store.setting("source_enabled_conversations", default: true)
        let mailEnabled = (source == nil || source == "apple-mail") &&
            sourceMayRun("apple-mail", requested: requestedSource) &&
            store.setting("source_enabled_apple-mail", default: true)
        let messagesEnabled = (source == nil || source == "messages") &&
            sourceMayRun("messages", requested: requestedSource) &&
            store.setting("source_enabled_messages", default: true)
        let notesEnabled = (source == nil || source == "notes") &&
            sourceMayRun("notes", requested: requestedSource) &&
            store.setting("source_enabled_notes", default: true)

        // Everything expensive off it: copying browser databases and walking session logs are both
        // file-system bound, and on the main actor they would be felt as a stuck launcher.
        let gathered = await Task.detached(priority: .utility) {
            let history = browsersEnabled
                ? BrowserHistory.read(since: since, excludedDomains: excludedDomains,
                                      excludedApps: excludedApps)
                : BrowserHistory.Reading(visits: [], problems: [])
            let exchanges = conversationsEnabled ? Self.conversations(since: since) : []
            let mail = mailEnabled ? LocalMailConnector.read(since: since)
                                   : LocalMailConnector.Reading(messages: [], problem: nil)
            let messages = messagesEnabled
                ? LocalMessagesConnector.read(since: since)
                : LocalMessagesConnector.Reading(messages: [], problem: nil)
            let notes = notesEnabled
                ? LocalNotesConnector.read(since: since)
                : LocalNotesConnector.Reading(notes: [], problem: nil)
            return (history, exchanges, mail, messages, notes)
        }.value

        let transcripts = source == nil ? await transcribePending(since: since) : []
        await refreshCorrections(root: corpusRoot)

        setPhase(.assembling, source: runSource)
        persistIngestionProgress(phase: .assembling, source: runSource,
                                 completedItems: gathered.0.visits.count + gathered.1.count
                                    + gathered.2.messages.count + gathered.3.messages.count
                                    + gathered.4.notes.count)
        persistCheckpoint(source: runSource, phase: .assembling, windowStart: since)

        let input = assemblyInput(now: now, visits: gathered.0.visits,
                                  exchanges: gathered.1, mails: gathered.2.messages,
                                  messages: gathered.3.messages,
                                  notes: gathered.4.notes,
                                  transcripts: transcripts)

        // The assembly is pure and the biggest single cost in the pass, so it runs off the main
        // actor too. Nothing it touches is shared.
        let corpus = await Task.detached(priority: .utility) {
            CorpusBuilder.assemble(input)
        }.value

        // Re-read rather than trusting the state captured at the top: a pass takes seconds and
        // somebody who hits pause during one means it, including for the work already done.
        guard isCapturing, !corpus.isPaused else {
            persistIngestionProgress(phase: .paused, source: runSource)
            recordRun(source: source, startedAt: startedAt, phase: Phase.paused.rawValue,
                      written: 0, problem: nil)
            return .paused
        }

        setPhase(.writing, source: runSource)
        persistIngestionProgress(phase: .writing, source: runSource,
                                 totalItems: corpus.items.count)
        persistCheckpoint(source: runSource, phase: .writing, windowStart: since)
        do {
            try await write(corpus)
        } catch {
            let problem = error.localizedDescription
            lastProblem = problem
            setPhase(.failed)
            persistIngestionProgress(phase: .failed, source: runSource,
                                     totalItems: corpus.items.count,
                                     writtenPassages: lastWritten, problem: problem)
            recordRun(source: source, startedAt: startedAt, phase: Phase.failed.rawValue,
                      written: lastWritten, problem: problem)
            return .failed(problem)
        }
        // A successful read is not a successful sync until the privacy gate has still allowed the
        // assembled corpus to be committed. Recording this before `write` made a paused run green.
        recordSource("browsers", enabled: browsersEnabled, count: gathered.0.visits.count,
                     problem: gathered.0.problems.first)
        recordSource("conversations", enabled: conversationsEnabled, count: gathered.1.count)
        recordSource("apple-mail", enabled: mailEnabled, count: gathered.2.messages.count,
                     problem: gathered.2.problem)
        recordSource("messages", enabled: messagesEnabled, count: gathered.3.messages.count,
                     problem: gathered.3.problem)
        recordSource("notes", enabled: notesEnabled, count: gathered.4.notes.count,
                     problem: gathered.4.problem)
        let problems = gathered.0.problems
            + [gathered.2.problem, gathered.3.problem, gathered.4.problem].compactMap { $0 }
        store.setSetting("corpus_last_problem", problems.joined(separator: "\n"))
        store.setSetting("corpus_last_run", String(now.timeIntervalSince1970))
        lastRun = now
        lastProblem = problems.first
        setPhase(lastProblem == nil ? .completed : .failed)
        persistIngestionProgress(phase: lastProblem == nil ? .completed : .failed,
                                 source: runSource, completedItems: corpus.items.count,
                                 totalItems: corpus.items.count,
                                 writtenPassages: lastWritten, problem: lastProblem)
        persistCheckpoint(source: runSource, phase: .completed, windowStart: since,
                          completed: lastProblem == nil)
        recordRun(source: source, startedAt: startedAt,
                  phase: phase.rawValue, written: lastWritten, problem: lastProblem)

        await distillIfDue(now: now)
        if let lastProblem { return .failed(lastProblem) }
        return .completed(written: lastWritten)
    }

    /// Reads power state once per scheduled pass. A missing power source is treated as unknown,
    /// never as an empty battery, so desktops and Macs with unusual UPS hardware keep working.
    private static func powerSource() -> (onBattery: Bool, fraction: Double?) {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let listed = IOPSCopyPowerSourcesList(info)?.takeUnretainedValue()
                as? [CFTypeRef],
              let source = listed.first,
              let raw = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                as? [String: Any],
              let state = raw[kIOPSPowerSourceStateKey] as? String else {
            return (false, nil)
        }
        let onBattery = state == kIOPSBatteryPowerValue
        let current = raw[kIOPSCurrentCapacityKey] as? Int
        let maximum = raw[kIOPSMaxCapacityKey] as? Int
        let fraction: Double? = if let current, let maximum, maximum > 0 {
            Double(current) / Double(maximum)
        } else { nil }
        return (onBattery, fraction)
    }

    private func recordRun(source: String?, startedAt: Date, phase: String,
                           written: Int, problem: String?) {
        let record = CorpusRunRecord(id: UUID().uuidString, startedAt: startedAt,
                                     finishedAt: .now, source: source, phase: phase,
                                     written: written, problem: problem)
        runHistory = Array(([record] + runHistory).prefix(20))
        guard let data = try? JSONEncoder().encode(runHistory),
              let raw = String(data: data, encoding: .utf8) else { return }
        store.setSetting("corpus_run_history", raw)
    }

    private func recordSource(_ id: String, enabled: Bool, count: Int, problem: String? = nil) {
        guard enabled else { return }
        store.setSetting("source_last_sync_\(id)", String(Date.now.timeIntervalSince1970))
        store.setSetting("source_last_count_\(id)", String(count))
        if let problem {
            let attempts = (Int(store.setting("source_retry_count_\(id)") ?? "0") ?? 0) + 1
            let delay = min(24 * 60 * 60, 30 * 60 * pow(2, Double(attempts - 1)))
            store.setSetting("source_retry_count_\(id)", String(attempts))
            store.setSetting("source_retry_after_\(id)",
                             String(Date.now.addingTimeInterval(delay).timeIntervalSince1970))
            store.setSetting("source_last_problem_\(id)", problem)
        } else {
            store.setSetting("source_retry_count_\(id)", "0")
            store.setSetting("source_retry_after_\(id)", "")
            store.setSetting("source_last_problem_\(id)", "")
        }
    }

    /// Scheduled passes back off after a connector failure. An explicit Sync button is a user's
    /// instruction to try now, so it bypasses the timer while still respecting the source toggle.
    private func sourceMayRun(_ id: String, requested: String?) -> Bool {
        guard requested == nil else { return true }
        guard let raw = store.setting("source_retry_after_\(id)"), let retryAfter = Double(raw),
              retryAfter > Date.now.timeIntervalSince1970 else { return true }
        return false
    }

    private func setPhase(_ phase: Phase, source: String? = nil) {
        self.phase = phase
        store.setSetting("corpus_run_phase", phase.rawValue)
        if let source { store.setSetting("corpus_run_source", source) }
        if phase == .failed, let lastProblem {
            store.setSetting("corpus_last_problem", lastProblem)
        }
    }

    private func persistIngestionProgress(
        phase: IngestionProgress.Phase,
        source: String,
        completedItems: Int = 0,
        totalItems: Int = 0,
        writtenPassages: Int = 0,
        problem: String? = nil
    ) {
        let progress = IngestionProgress(runID: currentRunID, source: source, phase: phase,
                                         completedItems: completedItems, totalItems: totalItems,
                                         writtenPassages: writtenPassages, problem: problem)
        guard let data = try? JSONEncoder().encode(progress),
              let raw = String(data: data, encoding: .utf8) else { return }
        store.setSetting("corpus_ingestion_progress", raw)
    }

    private func persistCheckpoint(source: String = "corpus",
                                   phase: IngestionCheckpoint.Phase,
                                   windowStart: Date, completed: Bool = false) {
        let existing = checkpoint?.canResume(source: source) == true ? checkpoint : nil
        let saved = IngestionCheckpoint(id: existing?.id ?? UUID().uuidString,
                                        source: source, windowStart: windowStart, phase: phase,
                                        completed: completed)
        checkpoint = completed ? nil : saved
        guard let data = try? JSONEncoder().encode(saved),
              let raw = String(data: data, encoding: .utf8) else { return }
        store.setSetting("corpus_checkpoint", raw)
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
                       mails: [MailMessage] = [],
                       messages: [MessageRecord] = [],
                       notes: [NoteRecord] = [],
                       transcripts: [Transcript]) -> CorpusBuilder.Input {
        let since = now.addingTimeInterval(-CorpusRunner.window)
        let mailNodes = mails.filter(MailRelevance.isWorthIndexing).map(Capture.mail).map(\.node)
        let messageNodes = messages.filter { $0.text.count >= 40 }
            .map(Capture.message).map(\.node)
        let noteNodes = notes.filter { $0.text.count >= 40 && !SecretGuard.carriesSecret($0.text) }
            .map(Capture.note).map(\.node)
        return CorpusBuilder.Input(
            nodes: store.nodes(limit: 2_000).filter {
                $0.lastSeen >= since && !$0.id.hasPrefix("episode:")
            } + mailNodes + messageNodes + noteNodes,
            clips: store.clips(limit: 500).filter { $0.createdAt >= since },
            exchanges: exchanges, visits: visits, mails: mails, messages: messages,
            notes: notes,
            transcripts: transcripts,
            forgotten: store.forgottenPeriods(),
            privacy: store.privacyState,
            excludedApps: store.excludedFromCapture(), excludedDomains: store.excludedDomains(),
            rejectedMerges: rejectedMerges(), markedByHand: markedByHand(), now: now
        )
    }

    /// Writes what the corpus decided into the index and the graph.
    ///
    /// Yields every few documents, and that is not a nicety. Each document is a DELETE plus one
    /// INSERT per passage, every insert firing the FTS5 triggers, and the store is on the main
    /// actor. A brain with eleven thousand passages therefore held the main thread for the whole
    /// pass with no gap in it at all: sampling the app during a launch found the main thread 64 %
    /// inside SQLite and 0 % waiting for events, which is the technical spelling of "BeLauncher
    /// no responde". The work is the same; the difference is that a keystroke now gets serviced
    /// between documents instead of after all of them.
    func write(_ corpus: Corpus) async throws {
        var written = 0
        for (index, item) in corpus.items.enumerated() {
            written += try store.replacePassagesChecked(for: item.source, title: item.title,
                                                        occurredAt: item.occurredAt,
                                                        text: item.text).count
            if index % 8 == 7 {
                persistIngestionProgress(phase: .writing, source: currentRunSource,
                                         completedItems: index + 1,
                                         totalItems: corpus.items.count,
                                         writtenPassages: written)
                await Task.yield()
            }
        }
        // Kept so Ajustes can say how much of the brain came from watching rather than from typing.
        // A capture that is on and producing nothing looks identical to one that is off.
        lastWritten = written
        store.setSetting("corpus_last_passages", String(written))
        persistIngestionProgress(phase: .writing, source: currentRunSource,
                                 completedItems: corpus.items.count,
                                 totalItems: corpus.items.count,
                                 writtenPassages: written)

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
                                      detail: L("Episode · ") + Self.when(episode.start),
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

        try publishCorpusFiles(corpus)

        Task { @MainActor [weak self] in
            _ = try? await self?.brain?.embedEverything(maximumBatches: 2)
        }
    }

    /// Publishes the open Markdown corpus through the same recoverable staging contract the
    /// reader/editor uses. The database is derived and searchable; these files are the person's
    /// audit surface and the place where corrections survive the next rebuild.
    private func publishCorpusFiles(_ corpus: Corpus) throws {
        let folder = try CorpusFolder(root: corpusRoot)
        let documents = corpus.episodes.map { episode in
            CorpusFiles.document(for: episode, links: entityLinks(for: episode, in: corpus))
        } + corpus.entities.map { entity in
            CorpusFiles.document(for: entity, seenAt: corpus.episodes
                .filter { $0.signals.contains { signal in entity.forms.contains(Identity.fold(signal.subject)) } }
                .map(\.start).max() ?? .now)
        }
        _ = try folder.saveBatch(documents)
    }

    private func entityLinks(for episode: Episode, in corpus: Corpus) -> [String] {
        let folded = Identity.fold(episode.subjects.joined(separator: " ")
            + " " + episode.signals.map(\.title).joined(separator: " "))
        var seen = Set<String>()
        return corpus.entities.compactMap { entity in
            guard entity.forms.contains(where: { !$0.isEmpty && folded.contains($0) }),
                  seen.insert(entity.canonical).inserted else { return nil }
            return entity.canonical
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
        let retryAfter = Double(store.setting("transcription_retry_after") ?? "") ?? 0
        guard retryAfter <= Date.now.timeIntervalSince1970 else { return [] }

        for entry in entries.sorted() where audio.contains((entry as NSString).pathExtension.lowercased()) {
            let path = (folder as NSString).appendingPathComponent(entry)
            guard !done.contains(path) else { continue }
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date, modified >= since
            else { continue }
            guard isCapturing else { break }

            do {
                result.append(try await VoiceProvider.transcribe(
                    fileAt: URL(fileURLWithPath: path), title: entry,
                    spokenLanguage: language))
                done.insert(path)
                store.setSetting("transcription_retry_count", "0")
                store.setSetting("transcription_retry_after", "")
            } catch {
                // A failure is not completion. Keep it eligible for a later pass, but back off so
                // an unavailable speech asset cannot make every scheduled run do the same work.
                let attempts = (Int(store.setting("transcription_retry_count") ?? "0") ?? 0) + 1
                let delay = min(24 * 60 * 60, 30 * 60 * pow(2, Double(attempts - 1)))
                store.setSetting("transcription_retry_count", String(attempts))
                store.setSetting("transcription_retry_after",
                                 String(Date.now.addingTimeInterval(delay).timeIntervalSince1970))
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
        guard BackgroundRunPolicy.isOvernight(hour: calendar.component(.hour, from: now)) else {
            return
        }

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
        if !statements.isEmpty, let folder = try? CorpusFolder(root: corpusRoot) {
            let titles = Dictionary(uniqueKeysWithValues: corpus.episodes.map { episode in
                (episode.id, episode.title.isEmpty ? episode.fallbackTitle : episode.title)
            })
            _ = try? folder.saveBatch(statements.map {
                CorpusFiles.document(for: $0, titles: titles)
            })
        }
        _ = try? await brain?.embedEverything(maximumBatches: 2)
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
