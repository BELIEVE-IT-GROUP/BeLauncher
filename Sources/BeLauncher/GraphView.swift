import SwiftUI
import AppKit
import BeLauncherCore

enum BELBrainNavigationNotification {
    static let notes = Notification.Name("com.believe.belauncher.brain.notes")
}

/// The graph of what you did.
///
/// Obsidian's graph is what you wrote. This one is what you did. Nobody types a node here and
/// nobody draws an edge: both come out of the day. That difference is the product, and it is also
/// why the viewer has to be ours — a brain you have to open somewhere else to look at is a
/// background index, and the person ends up living in the other app.
///
/// Three things it has to do, and failing one makes the other two not worth much. See what it
/// knows about you, which is what turns a black box into something you can trust. Correct it, which
/// is the one thing Obsidian cannot offer, because there is nothing to correct when you wrote it
/// all yourself. And navigate: click a node and land on what is underneath.
@MainActor
@Observable
final class GraphModel {

    struct Evidence: Identifiable, Equatable {
        enum Route: Equatable {
            case direct
            case connected(String)
            case matched

            var label: String {
                switch self {
                case .direct: L("This node")
                case .connected(let title): L("Connected: %@", title)
                case .matched: L("Name match")
                }
            }
        }

        let passage: IndexedPassage
        let route: Route

        var id: String { passage.id }
    }

    /// How far back to look.
    ///
    /// Time is a filter of the first order rather than a nicety. This is a graph of things that
    /// happened, so "show me March" is as reasonable a question as "show me this project", and a
    /// graph that can only answer the second one is a concept map wearing a timestamp.
    enum Span: String, CaseIterable, Identifiable {
        case week, month, quarter, everything

        var id: String { rawValue }

        var label: String {
            switch self {
            case .week: L("7 days")
            case .month: L("30 days")
            case .quarter: "3 meses"
            case .everything: L("Everything")
            }
        }

        var seconds: TimeInterval? {
            switch self {
            case .week: 7 * 86_400
            case .month: 30 * 86_400
            case .quarter: 90 * 86_400
            case .everything: nil
            }
        }
    }

    private let store: Store
    var sourceStore: Store { store }
    let corpus: CorpusFolder?
    private let now: Date

    // What was read out of the brain, before filtering.
    private var allNodes: [GraphLayout.Node] = []
    private var allLinks: [GraphLayout.Link] = []
    private var workNodes: [String: WorkNode] = [:]
    private var episodes: [String: Episode] = [:]
    private var documents: [String: CorpusDocument] = [:]
    private var rejected: Set<String> = []

    // Filters.
    var span: Span = .month { didSet { rebuild() } }
    var shapes: Set<GraphLayout.Node.Shape> = Set(GraphLayout.Node.Shape.allCases) { didSet { rebuild() } }
    var floor: Double = 0 { didSet { rebuild() } }
    var arrangement: GraphLayout.Arrangement = .force { didSet { rebuild() } }
    var query = "" { didSet { rebuild() } }

    // What is on screen.
    private(set) var drawing = GraphLayout.Drawing(nodes: [], lines: [], omitted: 0)

    /// What the library is handed. The positions are its problem, not ours: dragging, zooming and
    /// the endless canvas all come from it, and every one of those was missing while this app drew
    /// the graph itself.
    private(set) var web = BrainGraphData(nodes: [], links: [])

    /// Only pinned clips enter the review queue. The full chronological history belongs to the
    /// launcher's clipboard rail; the Brain should surface deliberate saves, not every copy.
    var pinnedInboxClips: [Clip] {
        store.clips(limit: 200).filter(\.isPinned)
    }

    var inboxItems: [InboxItem] {
        let records = QuickNote.records(inVaultAt: Vault.defaultRoot())
            .filter { !$0.reviewed }
            .map(InboxItem.init(record:))
        let clips = pinnedInboxClips.map(InboxItem.init(clip:))
        return (records + clips).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    func unpinInboxClip(_ clip: Clip) {
        store.setPinned(false, clip: clip.id)
    }
    private(set) var counted = 0
    /// Whether a layout is being worked out right now, so the empty canvas is not mistaken for an
    /// empty brain in the moment between a keystroke and its picture.
    private(set) var isLaying = false
    private var layout: Task<Void, Never>?
    var size = CGSize(width: 900, height: 600) { didSet { if size != oldValue { rebuild() } } }
    var selected: String?
    /// The second node, for the only question that needs two: are these the same thing?
    var compared: String?
    var hovered: String?
    var proposal: MergeProposal?
    var status: String?

    var recentDocuments: [CorpusDocument] {
        documents.values.sorted { $0.occurredAt > $1.occurredAt }.prefix(8).map { $0 }
    }

    var recentNodes: [WorkNode] {
        workNodes.values.sorted { $0.lastSeen > $1.lastSeen }.prefix(8).map { $0 }
    }

    var nodeCount: Int { workNodes.count + episodes.count }
    var relationCount: Int { allLinks.count }
    var documentCount: Int { documents.count }

    /// Pulse reads committed memory, not graph activity. Keeping that distinction here prevents
    /// a busy graph from masquerading as an urgent decision and lets the Overview show only real
    /// attention signals.
    var pulseSignals: [Pulse.Signal] {
        guard let vault = try? Vault(root: Vault.defaultRoot()) else { return [] }
        return Pulse.signals(for: vault.objects(), limit: 4)
    }

    /// Opening a node's Markdown. Injected because the reader is a window and the model is not
    /// allowed to know about windows — and because without it the graph told people to "open it in
    /// the reader" with no way to get there, which is the connection between the drawing and the
    /// files it draws.
    var onRead: ((String) -> Void)?
    var onPrimeLauncher: ((String) -> Void)?

    init(store: Store, corpus: CorpusFolder?, now: Date = .now) {
        self.store = store
        self.corpus = corpus
        self.now = now
        load()
    }

    // MARK: - Reading the brain

    func load() {
        let nodes = store.nodes(limit: 2_000)
        workNodes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

        let corpusDocuments = corpus?.documents() ?? []
        documents = Dictionary(corpusDocuments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rejected = CorpusFiles.rejected(in: corpusDocuments)
        let pinned = CorpusFiles.pinned(in: corpusDocuments)
        let hidden = CorpusFiles.hidden(in: corpusDocuments)

        // Episodes are assembled here rather than stored, because they are derived: the same
        // signals always produce the same episodes, and keeping a second copy in the database
        // would only create a way for the two to disagree.
        // Only the kinds that mean somebody was doing something. A person and a project are
        // *what* the work was about, not evidence that it happened, and letting them in produces
        // episodes made of nothing but the shape of the graph.
        let signals = nodes
            .filter { !hidden.contains($0.id) }
            .compactMap { node -> Episode.Signal? in
                guard let kind = signalKind(node.kind) else { return nil }
                return Episode.Signal(at: node.lastSeen, kind: kind,
                                      subject: node.id, title: node.name)
            }
        let built = EpisodeBuilder.episodes(from: signals, now: now)
        episodes = Dictionary(built.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // How many separate days each thing was touched on: the strongest relevance signal there
        // is, and the one that separates real work from a detour.
        var daysPerSubject: [String: Set<Int>] = [:]
        for signal in signals {
            let day = Int(signal.at.timeIntervalSince1970 / 86_400)
            daysPerSubject[signal.subject, default: []].insert(day)
        }

        var graphNodes: [GraphLayout.Node] = []
        var links: [GraphLayout.Link] = []

        for node in nodes where !hidden.contains(node.id) {
            let weight = pinned.contains(node.id) ? 1 : min(Double(node.weight) / 12, 0.95)
            graphNodes.append(GraphLayout.Node(id: node.id, label: node.name,
                                               shape: shape(node.kind), at: node.lastSeen,
                                               weight: weight))
        }

        for episode in built where !hidden.contains(episode.id) {
            let days = episode.subjects.compactMap { daysPerSubject[$0]?.count }.max() ?? 1
            let measured = Relevance.signals(for: episode, daysSeen: days,
                                             neighbours: episode.subjects.count,
                                             markedByHand: pinned.contains(episode.id))
            graphNodes.append(GraphLayout.Node(id: episode.id, label: episode.title,
                                               shape: .episode, at: episode.start,
                                               weight: Relevance.score(measured)))
            // Only the handful of things an episode was really about. Linking every signal turns
            // a long afternoon into a star with thirty spokes and hides the shape of everything
            // else on the canvas.
            for subject in episode.subjects.prefix(6) where workNodes[subject] != nil {
                links.append(GraphLayout.Link(source: episode.id, target: subject, strength: 1.2))
            }
        }

        let known = Set(graphNodes.map(\.id))
        for edge in workEdges() where known.contains(edge.source) && known.contains(edge.target) {
            links.append(GraphLayout.Link(source: edge.source, target: edge.target,
                                          strength: edge.kind == .partOf ? 1.4 : 0.8))
        }

        allNodes = graphNodes
        allLinks = links
        rebuild()
    }

    /// Every edge in one query. One query per node would be five hundred round trips to open a
    /// window.
    private func workEdges() -> [WorkEdge] {
        let rows = (try? store.database.query("SELECT * FROM work_edges")) ?? []
        return rows.compactMap { row in
            guard let kind = WorkEdge.Kind(rawValue: row.string("kind")) else { return nil }
            return WorkEdge(source: row.string("source"), target: row.string("target"),
                            kind: kind, at: Date(timeIntervalSince1970: row.double("at")))
        }
    }

    // MARK: - Filtering and placing

    /// How long a change waits before the graph is redrawn.
    ///
    /// Typing "waw" is one layout, not three. Measured at the budget of three hundred nodes a
    /// layout is around half a second, so without this a four-letter word queued two seconds of
    /// arithmetic whose first three quarters nobody would ever see.
    static let settle: Duration = .milliseconds(80)

    /// Filtering is cheap and stays here; placing is not and does not.
    ///
    /// The whole rebuild used to run on the main actor, which is what made the window freeze for
    /// about half a second on every keystroke in the filter. The filter itself is one pass over a
    /// few thousand nodes — that part is fine where it is, and doing it here is what lets the
    /// count update while the picture is still being worked out.
    /// The palette keys the page uses. Kept as strings because they cross into JavaScript, and a
    /// mismatch there fails by drawing everything grey rather than by failing to compile.
    /// One line, never a paragraph.
    ///
    /// Node labels come from clip and conversation titles, which are whole sentences. Handing
    /// those to the graph filled the canvas with overlapping walls of text.
    static func shortLabel(_ label: String) -> String {
        // A legacy source can contain an accidentally enormous title. Bound the input before
        // Foundation scans, folds or allocates it; truncating only after replacement made one
        // bad title capable of freezing the entire Brain window.
        let bounded = String(label.prefix(256))
        let flat = bounded.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > 34 ? String(flat.prefix(33)) + "…" : flat
    }

    static func typeName(_ shape: GraphLayout.Node.Shape) -> String {
        switch shape {
        case .episode: "episode"
        case .person: "person"
        case .project: "project"
        case .company: "company"
        case .topic: "topic"
        case .thing: "thing"
        }
    }

    /// Only edges that mean "this came out of that" carry particles, so the animation says
    /// something instead of decorating everything.
    private func linkKind(_ link: GraphLayout.Link) -> String {
        link.strength > 1 ? "cameFrom" : "workedWith"
    }

    func rebuild() {
        let cutoff = span.seconds.map { now.addingTimeInterval(-$0) }
        let needle = Identity.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))

        let visible = allNodes.filter { node in
            guard shapes.contains(node.shape), node.weight >= floor else { return false }
            if let cutoff, node.at < cutoff { return false }
            if !needle.isEmpty, !Identity.fold(node.label).contains(needle) { return false }
            return true
        }
        let ids = Set(visible.map(\.id))
        let links = allLinks.filter { ids.contains($0.source) && ids.contains($0.target) }
        let options = GraphLayout.Options(width: Double(size.width), height: Double(size.height),
                                          arrangement: arrangement)

        counted = visible.count
        web = BrainGraphData(
            nodes: visible.map {
                BrainGraphData.Node(id: $0.id, label: Self.shortLabel($0.label),
                                    type: Self.typeName($0.shape), weight: max($0.weight, 0.08))
            },
            links: links.map {
                BrainGraphData.Link(source: $0.source, target: $0.target,
                                    kind: linkKind($0), weight: $0.strength)
            }
        )
        // Cancelling before scheduling is the half of this that matters. The layout in flight is
        // for a filter the person has already moved past, and `GraphLayout.arrange` gives up
        // between passes, so the letter that arrives mid-layout stops the old one instead of
        // queueing behind it.
        layout?.cancel()
        isLaying = true
        layout = Task { [weak self] in
            try? await Task.sleep(for: GraphModel.settle)
            guard !Task.isCancelled else { return }
            let drawn = await GraphModel.place(nodes: visible, links: links, options: options)
            guard !Task.isCancelled else { return }
            self?.show(drawn)
        }
    }

    /// Off the main actor by being `nonisolated` and `async`, and a child of the task that started
    /// it so cancelling that task reaches the arithmetic. A detached task would not: it inherits
    /// nothing, cancellation included, and the layout would run to the end after the keystroke
    /// that abandoned it.
    private nonisolated static func place(nodes: [GraphLayout.Node], links: [GraphLayout.Link],
                                          options: GraphLayout.Options) async -> GraphLayout.Drawing {
        GraphLayout.arrange(nodes: nodes, links: links, options: options)
    }

    /// How many layouts have actually been drawn. Not decoration: it is how a test can tell that
    /// typing four letters produced one picture and not four.
    private(set) var layouts = 0

    private func show(_ drawn: GraphLayout.Drawing) {
        drawing = drawn
        layouts += 1
        isLaying = false
        if let selected, drawing.node(selected) == nil { self.selected = nil }
        if let compared, drawing.node(compared) == nil { self.compared = nil }
    }

    /// Waits for the layout in flight. The window never needs this; a graph whose placing cannot
    /// be awaited cannot be tested at all.
    func waitForLayout() async {
        await layout?.value
    }

    // MARK: - Selecting

    func tap(x: Double, y: Double, extending: Bool) {
        guard let hit = GraphLayout.nearest(toX: x, y: y, in: drawing) else {
            if !extending { selected = nil; compared = nil; proposal = nil }
            return
        }
        if extending, let selected, selected != hit.id {
            compared = hit.id
            askAboutPair()
        } else {
            selected = hit.id
            compared = nil
            proposal = nil
            status = nil
        }
    }

    func move(_ direction: GraphLayout.Direction) {
        guard let current = selected ?? drawing.nodes.last?.id else { return }
        if selected == nil { selected = current; return }
        if let next = GraphLayout.step(from: current, towards: direction, in: drawing) {
            selected = next
            proposal = nil
        }
    }

    var selectedNode: GraphLayout.Placed? { selected.flatMap { drawing.node($0) } }
    var comparedNode: GraphLayout.Placed? { compared.flatMap { drawing.node($0) } }

    func episode(_ id: String) -> Episode? { episodes[id] }
    func work(_ id: String) -> WorkNode? { workNodes[id] }
    func document(_ id: String) -> CorpusDocument? { documents[id] }
    func document(named name: String) -> CorpusDocument? {
        let wanted = Identity.fold(name)
        return documents.values.first { Identity.fold($0.title) == wanted }
            ?? documents.values.first { $0.links.contains(name) }
    }
    func hasSource(_ id: String) -> Bool { !(workNodes[id]?.target.isEmpty ?? true) }
    func readableDocument(_ id: String) -> CorpusDocument? { documents[id] ?? documentOrBuild(id) }

    func evidence(for id: String, limit: Int = 10) -> [Evidence] {
        var seen = Set<String>()
        var result: [Evidence] = []

        func append(_ passages: [IndexedPassage], route: Evidence.Route) {
            for passage in passages where result.count < limit {
                guard seen.insert(passage.id).inserted else { continue }
                guard !SecretGuard.carriesSecret(passage.title),
                      !SecretGuard.carriesSecret(passage.text) else { continue }
                result.append(Evidence(passage: passage, route: route))
            }
        }

        append(store.passages(for: IndexedSource(kind: .node, id: id)), route: .direct)

        let connected = store.relatedSources(to: IndexedSource(kind: .node, id: id), limit: 8)
        for source in connected where result.count < limit {
            let title = drawing.node(source.id)?.label ?? workNodes[source.id]?.name ?? source.id
            append(store.passages(for: source), route: .connected(title))
        }

        if let node = workNodes[id] ?? drawing.node(id).map({
            WorkNode(id: $0.id, kind: .file, name: $0.label, lastSeen: $0.at)
        }) {
            let matches = store.matchingWords(node.name, limit: 12)
                .compactMap { store.passage(id: $0) }
                .filter { $0.source.kind != .clip }
            append(matches, route: .matched)
        }

        return result
    }

    @discardableResult
    func materializeDocument(_ id: String) -> CorpusDocument? {
        if let document = documents[id] { return document }
        guard let document = documentOrBuild(id) else { return nil }
        guard let corpus else { return document }
        do {
            _ = try corpus.save(document)
            let saved = corpus.load(id: document.id, kind: document.kind) ?? document
            documents[saved.id] = saved
            return saved
        } catch {
            status = L("Could not write the brain file: %@", error.localizedDescription)
            return document
        }
    }

    func readHere() {
        guard let id = selected else { return }
        guard let document = materializeDocument(id) else {
            status = L("There is nothing readable for this node yet.")
            return
        }
        status = L("Reading “%@” here.", document.title)
    }

    /// Everything hanging off the selected node, ready to walk into.
    func neighbours(of id: String) -> [GraphLayout.Placed] {
        let ids = drawing.lines.compactMap { line -> String? in
            if line.source == id { return line.target }
            if line.target == id { return line.source }
            return nil
        }
        return Array(Set(ids)).compactMap { drawing.node($0) }
            .sorted { $0.weight > $1.weight }
    }

    /// Why something is in here, in words.
    func why(_ id: String) -> String {
        if documents[id]?.corrections.pinned == true { return L("You marked it as important yourself.") }
        if let episode = episodes[id] {
            return Relevance.explain(Relevance.signals(for: episode,
                                                       neighbours: episode.subjects.count))
        }
        guard let node = workNodes[id] else { return "" }
        return node.weight > 1
            ? L("It has turned up %@ times in what you do.", String(node.weight))
            : L("It has turned up once. That barely weighs anything.")
    }

    // MARK: - Corrections

    /// The question, when two entities might be one.
    ///
    /// Nothing merges silently, in either direction. A bad merge contaminates every future answer
    /// and cannot be seen from outside, so the strong evidence still gets shown before it is
    /// applied, and the weak evidence only ever asks.
    func askAboutPair() {
        proposal = nil
        guard let left = selected.flatMap(entity(for:)), let right = compared.flatMap(entity(for:)) else {
            status = L("Pick two entities to be able to join them.")
            return
        }
        switch Identity.decide(left, right, rejected: rejected) {
        case .merge(let reason):
            proposal = MergeProposal(left: left.canonical, right: right.canonical, reason: reason)
            status = nil
        case .ask(let asked):
            proposal = asked
            status = nil
        case .leaveAlone:
            status = rejected.isEmpty
                ? L("I see nothing saying “%1$@” and “%2$@” are the same thing.", left.canonical, right.canonical)
                : L("You already told me they are not the same. I will not ask again.")
        }
    }

    func entity(for id: String) -> Entity? {
        if let document = documents[id], let entity = CorpusFiles.entity(from: document) { return entity }
        guard let node = workNodes[id] else { return nil }
        return Entity(id: node.id, kind: entityKind(node.kind), canonical: node.name,
                      weight: node.weight)
    }

    /// Applies a merge, in the graph and in the corpus.
    func confirmMerge() {
        guard let proposal,
              let leftID = selected, let rightID = compared,
              let left = entity(for: leftID), let right = entity(for: rightID),
              let leftNode = workNodes[leftID], let rightNode = workNodes[rightID] else { return }

        let merged = Identity.merge(left, right)
        let winner = merged.id == left.id ? leftNode : rightNode
        let loser = merged.id == left.id ? rightNode : leftNode

        fold(loser, into: winner)
        if let corpus {
            var batch = [CorpusFiles.document(for: merged, seenAt: winner.lastSeen)]
            if let document = documents[loser.id] {
                batch.append(CorpusFiles.apply(.mergedInto(merged.id), to: document))
            }
            _ = try? corpus.saveBatch(batch)
        }
        status = L("“%1$@” is now an alias of “%2$@”. %3$@.", loser.name, merged.canonical,
                    proposal.reason.explanation.prefix(1).uppercased() + proposal.reason.explanation.dropFirst())
        self.proposal = nil
        compared = nil
        selected = merged.id
        load()
    }

    /// Says no, forever.
    ///
    /// Remembered rather than dismissed. Asking again next week is how correcting the brain stops
    /// feeling like teaching it and starts feeling like arguing with it, and the entire value of
    /// letting somebody correct the graph is that the correction sticks.
    func rejectMerge() {
        guard let proposal, let id = selected else { return }
        rejected.insert(proposal.id)
        if let corpus, let entity = entity(for: id) {
            let document = documents[id] ?? CorpusFiles.document(for: entity, seenAt: now)
            if let saved = try? corpus.apply(.rejectMerge(proposal), to: document) {
                documents[id] = saved
            }
        }
        status = L("Noted: not the same thing. I will not offer it again.")
        self.proposal = nil
        compared = nil
    }

    /// Pulls a name back out of an entity that swallowed it.
    func separate(alias: String) {
        guard let id = selected, let entity = entity(for: id), let corpus else { return }
        var trimmed = entity
        trimmed.aliases.remove(alias)
        let freed = Entity(kind: entity.kind, canonical: alias, weight: 1)

        var batch = [CorpusFiles.document(for: trimmed, seenAt: now),
                     CorpusFiles.document(for: freed, seenAt: now)]
        // The split has to reach the engine too, or tonight's pass folds them straight back
        // together and the correction looks like it never happened.
        let undo = MergeProposal(left: trimmed.canonical, right: alias, reason: .sameName)
        rejected.insert(undo.id)
        if let document = documents[id] ?? corpus.load(id: id, kind: .entity) ?? documentOrBuild(id) {
            batch.append(CorpusFiles.apply(.rejectMerge(undo), to: document))
        }
        _ = try? corpus.saveBatch(batch)
        store.upsertNode(WorkNode(id: WorkNode.identifier(kind: workKind(entity.kind), name: alias),
                                  kind: workKind(entity.kind), name: alias, lastSeen: now))
        status = L("“%@” is a separate thing again.", alias)
        load()
    }

    func markImportant(_ value: Bool) {
        guard let id = selected, let corpus, let document = documentOrBuild(id) else { return }
        // The subjects go with the mark. Written on its own, `pinned: true` was a note to the
        // reader and nothing else: the assembly compares `markedByHand` against the subjects of an
        // episode, so a mark that carried no subjects reached `Relevance.score` as nothing at all
        // and the thing said out loud to matter went on being ranked by dwell time.
        if let saved = try? corpus.apply(.markImportant(value, subjects: subjects(of: id)),
                                         to: document) {
            documents[id] = saved
        }
        status = value
            ? L("Marked. From now on it weighs the most in searches.")
            : L("Mark removed.")
        load()
    }

    /// What a correction on this node applies to, in the words the assembly uses.
    ///
    /// An episode names the things it was about; those survive the episode being rebuilt, and its
    /// own id does not — the id is derived from the signals it holds, so one more file that
    /// afternoon and it is a different episode.
    ///
    /// Both the node's id and whatever it points at, always. The graph files a signal under the
    /// node id and `CorpusBuilder` files it under the target when there is one, so a mark that
    /// named only one of the two would land on whichever side happened to agree with it. Naming
    /// both costs a string and is right either way; the two of them disagreeing about what a
    /// subject is called is worth fixing on its own, and not from here.
    private func subjects(of id: String) -> [String] {
        if let episode = episodes[id] { return episode.subjects.flatMap(names(of:)) }
        return names(of: id)
    }

    private func names(of id: String) -> [String] {
        guard let node = workNodes[id], !node.target.isEmpty else { return [id] }
        return [id, node.target]
    }

    /// Takes something out of the brain: out of the graph, out of the index and off the disk.
    ///
    /// Deleting the node was never enough. The node is derived — an episode is rebuilt from the
    /// signals underneath it and the identifiers come from their content, so the next pass put it
    /// back with the same id, and the app had said «fuera del cerebro» about something that came
    /// home half an hour later. What has to go is what produced it, which is what
    /// `Store.forget(_:)` does: it deletes the sources inside the stretch and writes the stretch
    /// into a ledger the assembly reads on every pass, so the rebuild cannot be exact any more.
    func forget() {
        guard let id = selected else { return }
        let name = drawing.node(id)?.label ?? "eso"
        if let corpus, let document = documentOrBuild(id) {
            // Recorded as a decision rather than only deleted: capturing the same file tomorrow
            // would otherwise bring it straight back, and a delete that undoes itself is worse
            // than no delete at all.
            _ = try? corpus.apply(.hide(true), to: document)
        }
        if let episode = episodes[id] {
            // The stretch the episode covers, not the episode row. Its signals are the original,
            // and they are what would build it again tonight.
            store.forget(Privacy.Period(from: episode.start, to: episode.end))
        }
        try? store.database.execute("DELETE FROM work_nodes WHERE id = ?", [.text(id)])
        try? store.database.execute("DELETE FROM work_edges WHERE source = ? OR target = ?",
                                    [.text(id), .text(id)])
        store.removePassages(for: IndexedSource(kind: .node, id: id))
        status = L("“%@” is out of the brain.", name)
        selected = nil
        load()
    }

    func showEverything() {
        span = .everything
        shapes = Set(GraphLayout.Node.Shape.allCases)
        floor = 0
        query = ""
        status = L("Showing the full local graph.")
    }

    func showRecent() {
        span = .week
        shapes = Set(GraphLayout.Node.Shape.allCases)
        floor = 0
        query = ""
        status = L("Showing the last 7 days.")
    }

    func primeLauncher(_ phrase: String) {
        onPrimeLauncher?(phrase)
    }

    private func documentOrBuild(_ id: String) -> CorpusDocument? {
        if let document = documents[id] { return document }
        if let episode = episodes[id] { return CorpusFiles.document(for: episode) }
        if let entity = entity(for: id) { return CorpusFiles.document(for: entity, seenAt: now) }
        return nil
    }

    private func fold(_ loser: WorkNode, into winner: WorkNode) {
        // New edges first, then the old ones go: doing it the other way round loses every
        // connection the absorbed node had, which is most of what made it worth merging.
        for edge in store.edges(from: loser.id) {
            let source = edge.source == loser.id ? winner.id : edge.source
            let target = edge.target == loser.id ? winner.id : edge.target
            guard source != target else { continue }
            store.link(WorkEdge(source: source, target: target, kind: edge.kind, at: edge.at))
        }
        try? store.database.execute("DELETE FROM work_edges WHERE source = ? OR target = ?",
                                    [.text(loser.id), .text(loser.id)])
        try? store.database.execute("DELETE FROM work_nodes WHERE id = ?", [.text(loser.id)])
        store.removePassages(for: IndexedSource(kind: .node, id: loser.id))
    }

    // MARK: - Navigating

    /// Opens whatever is underneath: the file, the page, the app.
    func open() {
        guard let id = selected else { return }
        if hasSource(id) { openSource(); return }
        // Nothing outside to open should not throw a second empty-looking window at the person.
        // The graph is the surface they are using; read it here unless they explicitly ask for the
        // Markdown file.
        readHere()
    }

    func openSource() {
        guard let id = selected, let node = workNodes[id], !node.target.isEmpty else {
            status = L("This node has no source to open.")
            return
        }
        if node.target.hasPrefix("http"), let url = URL(string: node.target) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: node.target))
        }
        status = nil
    }

    func openBrainFile() {
        guard let id = selected else { return }
        guard materializeDocument(id) != nil else {
            status = L("There is nothing readable for this node yet.")
            return
        }
        onRead?(id)
        status = nil
    }

    // MARK: - Kinds

    private func shape(_ kind: WorkNode.Kind) -> GraphLayout.Node.Shape {
        switch kind {
        case .person: .person
        case .company: .company
        case .project: .project
        case .meeting, .conversation, .decision, .commitment: .topic
        case .file, .application: .thing
        }
    }

    private func entityKind(_ kind: WorkNode.Kind) -> Entity.Kind {
        switch kind {
        case .person: .person
        case .company: .company
        case .project: .project
        default: .topic
        }
    }

    private func workKind(_ kind: Entity.Kind) -> WorkNode.Kind {
        switch kind {
        case .person: .person
        case .company: .company
        case .project: .project
        case .topic: .file
        }
    }

    private func signalKind(_ kind: WorkNode.Kind) -> Episode.Signal.Kind? {
        switch kind {
        case .file: .file
        case .application: .application
        case .meeting: .meeting
        case .conversation: .conversation
        case .decision, .commitment: .note
        case .person, .company, .project: nil
        }
    }
}

// MARK: - The view

@MainActor
struct GraphView: View {
    private enum Surface: String, CaseIterable, Identifiable {
        case overview, notes, graph
        var id: String { rawValue }
    }

    @Bindable var model: GraphModel
    @Bindable var coordinator: BrainCommandCoordinator
    @Bindable var corpusRunner: CorpusRunner
    let askBrain: @MainActor (String, BrainConversationContext?) async throws -> BrainAnswer
    let importText: @MainActor (String, String) -> Void
    let importFile: @MainActor (URL) -> Void
    let retryTranscription: @MainActor (QuickNote.Record) -> Void
    let saveNote: @MainActor (String) -> Void
    let runMission: @MainActor (Mission,
                                @escaping @Sendable @MainActor (MissionReceipt) -> Void) -> Void
    let cancelMission: @MainActor (Mission) -> Void
    let runIntent: @MainActor (String) -> Void
    let openCitation: @MainActor (BrainCitation) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reader: CorpusReaderModel?
    @State private var mission: Mission?
    @State private var noteDraft = ""
    @State private var showingNoteComposer = false
    @State private var surface: Surface = .overview
    @State private var inboxRecords = QuickNote.records(inVaultAt: Vault.defaultRoot()).filter { !$0.reviewed }
    @State private var inboxItems: [InboxItem] = []
    @State private var inboxRecord: QuickNote.Record?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            VerbRail(model: model,
                     selectedSurface: surface.rawValue,
                     showOverview: { surface = .overview },
                     showNotes: { surface = .notes },
                     showGraph: { surface = .graph })
                .frame(width: 236)
            Divider().opacity(0.35)
            VStack(spacing: 0) {
                controls
                Divider().opacity(0.35)
                BrainConversationView(coordinator: coordinator,
                                      context: {
                                          guard let document = reader?.selected else { return nil }
                                          return BrainConversationContext(
                                              sourceID: document.id,
                                              title: document.title,
                                              body: String(document.body.prefix(6_000)))
                                      },
                                      ask: askBrain,
                                      importText: importText, importFile: importFile,
                                      saveNote: { text in
                                          noteDraft = text
                                          showingNoteComposer = true
                                      },
                                      newNote: {
                                          noteDraft = ""
                                          showingNoteComposer = true
                                      },
                                      prepareMission: prepareMission,
                                      runIntent: runIntent,
                                      openCitation: openCitation)
                Divider().opacity(0.35)
                if let reader {
                    BrainReaderSurface(model: reader) {
                        self.reader = nil
                    }
                } else if surface == .overview {
                    BrainOverview(model: model,
                                  corpusRunner: corpusRunner,
                                  newNote: beginNewNote,
                                  importFile: importFile,
                                  runIntent: runIntent,
                                  inboxItems: inboxItems,
                                  openInbox: { item in
                                      if let path = item.sourcePath {
                                          inboxRecord = inboxRecords.first { $0.path == path }
                                      }
                                  },
                                  showNotes: { surface = .notes },
                                  refreshInbox: reloadInbox,
                                  rememberClip: { item in
                                      runIntent("remember this clipboard capture: \(item.excerpt)")
                                  },
                                  dismissClip: { item in
                                      if let id = item.clipID {
                                          model.unpinInboxClip(Clip(id: id, text: item.excerpt))
                                      }
                                      reloadInbox()
                                  },
                                  pulseSignals: model.pulseSignals,
                                  askAboutPulse: { signal in
                                      runIntent("what should we do about \(signal.headline)")
                                  },
                                  openReader: { id in
                                      guard let corpus = model.corpus else { return }
                                      reader = CorpusReaderModel(folder: corpus, selecting: id)
                                  },
                                  showGraph: { surface = .graph })
                } else if surface == .notes {
                    BrainNotesView(
                        newNote: beginNewNote,
                        retryTranscription: { retryTranscription($0) },
                        refresh: reloadInbox)
                } else {
                    HStack(spacing: 0) {
                        canvas
                        Divider().opacity(0.35)
                        Inspector(model: model, read: openReader)
                            .frame(width: 320)
                            .transition(.move(edge: .trailing))
                    }
                }
                Divider().opacity(0.35)
                footer
            }
        }
        .frame(minWidth: 1120, minHeight: 680)
        .background(Backdrop())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.selected)
        .sheet(item: $mission) { mission in
            BrainMissionView(mission: mission,
                             run: { completion in runMission(mission, completion) },
                             cancel: { cancelMission(mission) })
        }
        .sheet(isPresented: $showingNoteComposer) {
            BrainNoteComposer(initialText: noteDraft) { text in
                saveNote(text)
                reloadInbox()
                showingNoteComposer = false
            }
        }
        .sheet(item: $inboxRecord) { record in
            BrainInboxNoteView(record: record,
                               proposeMemory: { text in
                                   runIntent("remember that \(text)")
                               },
                               retryTranscription: { retryTranscription(record) },
                               markReviewed: {
                                   try? QuickNote.markReviewed(record)
                                   reloadInbox()
                                   inboxRecord = nil
                               })
        }
        .onAppear { reloadInbox() }
        .onReceive(NotificationCenter.default.publisher(for: BELBrainNavigationNotification.notes)) { _ in
            surface = .notes
            reloadInbox()
        }
    }

    private func reloadInbox() {
        inboxRecords = QuickNote.records(inVaultAt: Vault.defaultRoot()).filter { !$0.reviewed }
        inboxItems = model.inboxItems
    }

@MainActor
private struct BrainReaderSurface: View {
    @Bindable var model: CorpusReaderModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { close() } label: {
                    Label(L("Back to Brain"), systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape)
                Text(L("Reading your Brain")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(L("Markdown you own")).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            CorpusReaderView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: Controls

    private var controls: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                BeLauncherMark(side: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("What the brain knows about you"))
                        .font(.system(size: 13, weight: .semibold))
                    // Counts what was handed to the canvas, not what a parallel layout worked out.
                    // Reading one number off `drawing` and drawing from `web` is how a header ends
                    // up confidently describing a graph that is not the one on screen.
                    Text(L("%1$@ nodes · %2$@ relations",
                           String(model.web.nodes.count), String(model.web.links.count)))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Picker("", selection: $surface) {
                Text(L("Overview")).tag(Surface.overview)
                Text(L("My notes")).tag(Surface.notes)
                Text(L("Graph")).tag(Surface.graph)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220)

            if surface == .graph {
              Picker("", selection: $model.span) {
                ForEach(GraphModel.Span.allCases) { Text($0.label).tag($0) }
              }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            .help(L("Time is a first-class axis: this is a graph of things that happened."))

            Picker("", selection: $model.arrangement) {
                ForEach(GraphLayout.Arrangement.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 190)

            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: $model.floor, in: 0...0.9).frame(width: 84)
            }
            .help(L("Raise the relevance bar and whatever barely weighs anything goes."))

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Filtrar", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 120)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.white.opacity(0.07), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: Canvas

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            // The graph itself: force-graph 1.51.4, the same engine GetMaas, Maasy and BeMail
            // draw with. Nodes drag, the wheel zooms, the canvas has no edges — none of which the
            // hand-written version had, and none of which was worth rebuilding.
            BrainWebView(
                graph: model.web,
                onSelect: { id in model.selected = id.isEmpty ? nil : id },
                onCompare: { id in model.compared = id },
                onOpen: { id in model.selected = id; model.open() },
                // Shown where the person is already looking. A drawing that failed halfway should
                // say so on the window, not only in a log nobody opens.
                onTrouble: { model.status = $0 }
            )
            .ignoresSafeArea()

            if model.web.isEmpty, !model.isLaying { emptyState }
        }
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.return) { model.open(); return .handled }
        .onKeyPress("l") { model.readHere(); return .handled }
        .onKeyPress(.space) { model.markImportant(true); return .handled }
        .onKeyPress(.delete) { model.forget(); return .handled }
        .onKeyPress(.escape) { model.selected = nil; model.compared = nil; return .handled }
    }

    /// Said with the reason, not with a shrug. "Aquí no hay nada" over a brain that is simply
    /// filtered to last week is the fastest way to make somebody think they lost everything.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Mascot(height: 92)
            Text(model.query.isEmpty
                 ? L("There is nothing to draw here yet.")
                 : L("Nothing matches “%@”.", model.query))
                .font(.system(size: 13, weight: .medium))
            Text(model.query.isEmpty
                 ? L("The brain fills itself while you work, if you turned capture on. Try “Everything” up top.")
                 : L("Try fewer words, or widen the period."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 340)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Drawing

    /// Labels only where they can be read: what is selected or pointed at, plus the heaviest
    /// handful. A label on every node is a grey rectangle, not information.
    private var labelledNodes: Set<String> {
        Set(model.drawing.nodes.suffix(24).map(\.id))
            .union([model.selected, model.hovered, model.compared].compactMap { $0 })
    }

    private func drawLines(_ context: inout GraphicsContext) {
        for line in model.drawing.lines {
            let touched = line.source == model.selected || line.target == model.selected
                || line.source == model.hovered || line.target == model.hovered
            var path = Path()
            path.move(to: CGPoint(x: line.fromX, y: line.fromY))
            path.addLine(to: CGPoint(x: line.toX, y: line.toY))
            context.stroke(path,
                           with: .color(touched ? Theme.cyan.opacity(0.75) : .white.opacity(0.13)),
                           lineWidth: touched ? 1.6 : 0.8)
        }
    }

    private func drawNodes(_ context: inout GraphicsContext) {
        // Labels only where they can be read: everything selected or pointed at, plus the heaviest
        // handful. A label on every node is a grey rectangle, not information.
        let labelled = Set(model.drawing.nodes.suffix(24).map(\.id))
            .union([model.selected, model.hovered, model.compared].compactMap { $0 })

        for node in model.drawing.nodes {
            let rect = CGRect(x: node.x - node.radius, y: node.y - node.radius,
                              width: node.radius * 2, height: node.radius * 2)
            let colour = tint(node.shape)
            context.fill(Path(ellipseIn: rect), with: .color(colour.opacity(0.85)))
            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.35)), lineWidth: 0.8)

            if node.id == model.selected || node.id == model.compared {
                let ring = rect.insetBy(dx: -5, dy: -5)
                context.stroke(Path(ellipseIn: ring),
                               with: .color(node.id == model.selected ? Theme.cyan : .white),
                               style: StrokeStyle(lineWidth: 2,
                                                  dash: node.id == model.compared ? [3, 3] : []))
            }

            guard labelled.contains(node.id) else { continue }
            let text = Text(node.label)
                .font(.system(size: 10.5, weight: node.id == model.selected ? .semibold : .regular))
                .foregroundStyle(.white.opacity(node.id == model.selected ? 1 : 0.75))
            context.draw(context.resolve(text),
                         at: CGPoint(x: node.x, y: node.y + node.radius + 9), anchor: .top)
        }
    }

    /// The months, when time is the axis. Without them the horizontal position means nothing.
    private func drawAxis(_ context: inout GraphicsContext, size: CGSize) {
        let dates = model.drawing.nodes.map(\.at)
        guard let earliest = dates.min(), let latest = dates.max(), latest > earliest else { return }
        let span = latest.timeIntervalSince(earliest)
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateFormat = span > 80 * 86_400 ? "MMM" : "d MMM"

        var tick = calendar.date(from: calendar.dateComponents([.year, .month], from: earliest)) ?? earliest
        while tick <= latest {
            let fraction = tick.timeIntervalSince(earliest) / span
            let x = 34 + fraction * (size.width - 68)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 22))
            path.addLine(to: CGPoint(x: x, y: size.height - 10))
            context.stroke(path, with: .color(.white.opacity(0.07)), lineWidth: 1)
            context.draw(context.resolve(Text(formatter.string(from: tick))
                .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.4))),
                at: CGPoint(x: x, y: 10), anchor: .top)
            guard let next = calendar.date(byAdding: .month, value: 1, to: tick) else { break }
            tick = next
        }
    }

    private func tint(_ shape: GraphLayout.Node.Shape) -> Color {
        switch shape {
        case .episode: Theme.cyan
        case .person: Color(red: 0.62, green: 0.78, blue: 1)
        case .project: Color(red: 0.42, green: 0.56, blue: 0.98)
        case .company: Color(red: 0.78, green: 0.68, blue: 1)
        case .topic: Color(red: 0.55, green: 0.85, blue: 0.82)
        case .thing: Color(red: 0.72, green: 0.75, blue: 0.82)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let run = coordinator.current {
                Label(L("%@ · %@", run.label, run.source),
                      systemImage: run.state == .cancelling ? "hourglass" : "bolt.horizontal")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Button(L("Cancel command")) { coordinator.cancel() }
                    .buttonStyle(.borderless).font(.system(size: 11))
                    .disabled(run.state != .running)
            } else if let status = model.status {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            } else if let note = model.drawing.omittedNote {
                Label(note, systemImage: "eye.slash")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    KeyCap(symbol: "↑↓←→", label: "moverte")
                    KeyCap(symbol: "⏎", label: L("open"))
                    KeyCap(symbol: "L", label: "leer")
                    KeyCap(symbol: "␣", label: "importante")
                    KeyCap(symbol: "⌫", label: "olvidar")
                    KeyCap(symbol: "⇧+clic", label: "comparar dos")
                }
            }
            Spacer()
            ForEach(GraphLayout.Node.Shape.allCases, id: \.self) { shape in
                Button {
                    if model.shapes.contains(shape) { model.shapes.remove(shape) }
                    else { model.shapes.insert(shape) }
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(tint(shape)).frame(width: 7, height: 7)
                        Text(shape.label).font(.system(size: 10))
                    }
                    .opacity(model.shapes.contains(shape) ? 1 : 0.32)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func openReader() {
        guard let corpus = model.corpus else {
            model.status = L("No corpus folder is set up yet.")
            return
        }
        if let selected = model.selected, model.materializeDocument(selected) == nil {
            model.status = L("There is nothing readable for this node yet.")
            return
        }
        reader = CorpusReaderModel(folder: corpus, selecting: model.selected)
    }

    private func beginNewNote() {
        noteDraft = ""
        showingNoteComposer = true
    }

    private func prepareMission(_ answer: String) {
        let brief = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else { return }
        mission = MissionPlanner.plan("turn this into a proposal \(brief)")
    }
}

@MainActor
private struct BrainOverview: View {
    private enum InboxFilter: String, CaseIterable, Identifiable {
        case all, notes, evidence, clipboard

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: L("All")
            case .notes: L("Notes")
            case .evidence: L("Evidence")
            case .clipboard: L("Clipboard")
            }
        }
    }

    @Bindable var model: GraphModel
    @Bindable var corpusRunner: CorpusRunner
    let newNote: () -> Void
    let importFile: @MainActor (URL) -> Void
    let runIntent: @MainActor (String) -> Void
    let inboxItems: [InboxItem]
    let openInbox: (InboxItem) -> Void
    let showNotes: () -> Void
    let refreshInbox: () -> Void
    let rememberClip: (InboxItem) -> Void
    let dismissClip: (InboxItem) -> Void
    let pulseSignals: [Pulse.Signal]
    let askAboutPulse: (Pulse.Signal) -> Void
    let openReader: (String) -> Void
    let showGraph: () -> Void
    @State private var inboxFilter: InboxFilter = .all
    @State private var showingImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(L("Today in your Brain"))
                            Text(L("Ready"))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.cyan)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Theme.cyan.opacity(0.12), in: Capsule())
                        }
                            .font(.system(size: 24, weight: .semibold))
                        Text(L("Read, question and turn what matters into action."))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Button { newNote() } label: {
                        Label(L("New note"), systemImage: "note.text.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { showingImporter = true } label: {
                        Label(L("Import file"), systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.bordered)
                    Button { runIntent("record a voice note") } label: {
                        Label(L("Voice note"), systemImage: "waveform")
                    }
                    .buttonStyle(.bordered)
                    Button { runIntent("ask my Brain") } label: {
                        Label(L("Ask Brain"), systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .buttonStyle(.bordered)
                    Button { runIntent("create a mission") } label: {
                        Label(L("Plan a task"), systemImage: "checklist")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Text(L("Everything stays on this Mac"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .controlSize(.small)

                HStack(spacing: 10) {
                    stat(L("Remembered"), value: model.nodeCount, symbol: "circle.grid.2x2")
                    stat(L("Connections"), value: model.relationCount, symbol: "arrow.triangle.branch")
                    stat(L("Notes"), value: model.documentCount, symbol: "doc.text")
                }

                section(title: L("Brain updates"), symbol: "arrow.triangle.2.circlepath") {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: captureSymbol)
                            .foregroundStyle(corpusRunner.phase == .failed ? .orange : Theme.cyan)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(captureTitle).font(.system(size: 12, weight: .medium))
                            Text(captureDetail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                section(title: L("Where your Brain looks"), symbol: "square.stack.3d.up") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(KnowledgeSourceCatalog.current) { source in
                            let state = LocalSourceHealth.state(for: source, store: model.sourceStore)
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: source.symbol)
                                    .frame(width: 18)
                                    .foregroundStyle(state == .planned ? .secondary : Theme.cyan)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(source.title).font(.system(size: 12, weight: .medium))
                                        Text(sourceState(state))
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(state == .planned ? .secondary : Theme.cyan)
                                    }
                                    Text(source.scope).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                section(title: L("Worth your attention"), symbol: "waveform.path.ecg") {
                    if pulseSignals.isEmpty {
                        Text(L("Nothing needs attention right now."))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        ForEach(pulseSignals) { signal in
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: pulseSymbol(signal.kind))
                                    .foregroundStyle(signal.weight >= 90 ? Theme.accent : Theme.cyan)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(signal.headline).font(.system(size: 12, weight: .medium))
                                    Text(signal.detail).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 6)
                                Button(L("Ask Brain")) { askAboutPulse(signal) }
                                    .buttonStyle(.borderless).font(.caption)
                            }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    section(title: L("Recent notes"), symbol: "clock") {
                        if model.recentDocuments.isEmpty {
                            Text(L("Your Brain has no readable notes yet."))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        } else {
                            ForEach(model.recentDocuments) { document in
                                Button { openReader(document.id) } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: "doc.text").foregroundStyle(Theme.accent)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(document.title).lineLimit(1)
                                            Text("\(document.kind.label) · \(stamp(document.occurredAt))")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    section(title: L("Recent work"), symbol: "waveform.path.ecg") {
                        if model.recentNodes.isEmpty {
                            Text(L("The graph will appear here as the Brain learns."))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        } else {
                            ForEach(model.recentNodes) { node in
                                Button {
                                    model.selected = node.id
                                    showGraph()
                                } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: node.kind.symbol).foregroundStyle(Theme.cyan)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(node.name).lineLimit(1)
                                            Text(node.kind.label).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.up.right").font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                section(title: L("Inbox"), symbol: "tray") {
                    HStack(spacing: 10) {
                        Picker(L("Inbox filter"), selection: $inboxFilter) {
                            ForEach(InboxFilter.allCases) { filter in
                                Text(filter.label).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Spacer()
                        Button { refreshInbox() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help(L("Refresh Inbox"))
                        Button { showNotes() } label: {
                            Label(L("Open all notes"), systemImage: "arrow.up.right")
                        }
                        .buttonStyle(.borderless)
                    }

                    if filteredInboxItems.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("Nothing is waiting for review."))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Button { newNote() } label: {
                                Label(L("Write a note"), systemImage: "square.and.pencil")
                            }
                            .buttonStyle(.borderless)
                        }
                    } else {
                        ForEach(filteredInboxItems.prefix(10)) { item in
                            if item.kind == .clipboard {
                                HStack(spacing: 9) {
                                    inboxRow(symbol: "paperclip", title: item.title,
                                             detail: item.excerpt, tint: Theme.cyan)
                                    Button { rememberClip(item) } label: {
                                        Image(systemName: "brain.head.profile")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(L("Remember in Brain"))
                                    Button { dismissClip(item) } label: {
                                        Image(systemName: "pin.slash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(L("Remove from Inbox"))
                                }
                            } else {
                                Button { openInbox(item) } label: {
                                    inboxRow(symbol: item.kind == .evidence ? "waveform" : "note.text",
                                         title: item.title,
                                         detail: item.state == .needsTranscription
                                            ? L("Ready to transcribe · click to continue")
                                            : L("Ready for your review · click to continue"),
                                         tint: item.state == .needsTranscription ? .orange : Theme.accent)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Button { showGraph() } label: {
                    Label(L("Explore the full graph"), systemImage: "circle.grid.cross")
                }
                .buttonStyle(.borderless)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.item, .text, .plainText, .pdf, .data]) { result in
            if case .success(let url) = result { importFile(url) }
        }
    }

    private func stat(_ title: String, value: Int, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: symbol).foregroundStyle(Theme.accent)
            Text(String(value)).font(.system(size: 22, weight: .semibold))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private func section<Content: View>(title: String, symbol: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func pulseSymbol(_ kind: Pulse.Signal.Kind) -> String {
        switch kind {
        case .contradiction: "exclamationmark.triangle"
        case .overdue: "clock.badge.exclamationmark"
        case .stale: "clock"
        case .unsupported: "questionmark.circle"
        case .ownerless: "person.crop.circle.badge.questionmark"
        case .gap: "arrow.triangle.branch"
        }
    }

    private func sourceState(_ state: KnowledgeSource.State) -> String {
        switch state {
        case .connected: return L("Connected")
        case .available: return L("Available")
        case .manual: return L("Manual")
        case .planned: return L("Planned")
        }
    }

    private func inboxRow(symbol: String, title: String, detail: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var filteredInboxItems: [InboxItem] {
        switch inboxFilter {
        case .all: inboxItems
        case .notes: inboxItems.filter { $0.kind == .note }
        case .evidence: inboxItems.filter { $0.kind == .evidence }
        case .clipboard: inboxItems.filter { $0.kind == .clipboard }
        }
    }

    private var captureTitle: String {
        switch corpusRunner.phase {
        case .idle: L("Capture is not running")
        case .waiting: L("Capture is waiting")
        case .gathering: L("Capture is reading sources")
        case .assembling: L("Capture is assembling the Brain")
        case .writing: L("Capture is writing")
        case .completed: L("Capture completed")
        case .paused: L("Capture is paused")
        case .deferred: L("Capture is deferred")
        case .failed: L("Capture needs attention")
        }
    }

    private var captureDetail: String {
        if corpusRunner.lastWritten > 0 {
            return L("%@ fragments in the last pass", String(corpusRunner.lastWritten))
        }
        return L("Nothing has been written by the background pass yet.")
    }

    private var captureSymbol: String {
        switch corpusRunner.phase {
        case .failed: "exclamationmark.triangle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        default: "arrow.triangle.2.circlepath"
        }
    }
}

@MainActor
private struct BrainNotesView: View {
    let newNote: () -> Void
    let retryTranscription: (QuickNote.Record) -> Void
    let refresh: () -> Void
    @State private var notes: [QuickNote.Record] = []
    @State private var query = ""
    @State private var selectedID: String?
    @State private var draft = ""
    @State private var editing = false
    @State private var status: String?

    private var filtered: [QuickNote.Record] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return notes }
        return notes.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.excerpt.localizedCaseInsensitiveContains(needle)
        }
    }

    private var selected: QuickNote.Record? {
        notes.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("My notes")).font(.system(size: 18, weight: .semibold))
                    Text(L("Write, edit and keep your Markdown notes in one place."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L("Refresh notes"))
                Button(action: newNote) {
                    Label(L("New note"), systemImage: "note.text.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(L("Search notes"), text: $query)
                            .textFieldStyle(.plain)
                    }
                    .padding(12)
                    Divider()
                    if filtered.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "note.text").font(.title2).foregroundStyle(.secondary)
                            Text(notes.isEmpty ? L("No notes yet") : L("No notes match your search"))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filtered) { note in noteRow(note) }
                            }
                        }
                    }
                }
                .frame(minWidth: 270, idealWidth: 320, maxWidth: 390)
                noteDetail
                    .frame(minWidth: 480)
            }
        }
        .onAppear { reload() }
    }

    private func noteRow(_ note: QuickNote.Record) -> some View {
        Button {
            selectedID = note.id
            draft = body(of: note)
            editing = false
            status = nil
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: note.state == .needsTranscription ? "waveform" : "note.text")
                    .foregroundStyle(note.state == .needsTranscription ? .orange : Theme.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text(note.title).lineLimit(1)
                    Text(note.state == .needsTranscription
                         ? L("Ready to transcribe")
                         : (note.reviewed ? L("Reviewed") : L("Needs review")))
                        .font(.caption).foregroundStyle(note.state == .needsTranscription ? .orange : .secondary)
                }
                Spacer(minLength: 4)
                if note.reviewed { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(note.id == selectedID ? Theme.accent.opacity(0.16) : .clear)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var noteDetail: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selected.title).font(.system(size: 16, weight: .semibold))
                        Text(L("Markdown note · %@", selected.reviewed ? L("reviewed") : L("in Inbox")))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selected.state == .needsTranscription {
                        Button(L("Transcribe now")) { retryTranscription(selected) }
                            .buttonStyle(.borderedProminent)
                    }
                    if editing {
                        Button(L("Cancel")) { draft = body(of: selected); editing = false }
                        Button(L("Save")) { save(selected) }.buttonStyle(.borderedProminent)
                    } else {
                        Button(L("Edit")) { draft = body(of: selected); editing = true }
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selected.path)])
                    } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless)
                        .help(L("Open the Markdown file in Finder"))
                }
                .padding(18)
                Divider()
                if editing {
                    TextEditor(text: $draft)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(14)
                } else {
                    ScrollView {
                        MarkdownBody(text: body(of: selected), follow: { _ in })
                            .padding(22)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !selected.reviewed {
                    Divider()
                    HStack {
                        Text(L("Review this note when you are done with it."))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Mark as reviewed")) {
                            try? QuickNote.markReviewed(selected)
                            reload()
                        }
                    }
                    .padding(12)
                }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary).padding(12)
                }
            }
        } else {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "note.text").font(.largeTitle).foregroundStyle(.secondary)
                Text(L("Select a note to read or edit")).font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func body(of note: QuickNote.Record) -> String {
        guard let raw = try? String(contentsOfFile: note.path, encoding: .utf8) else { return note.excerpt }
        return QuickNote.body(from: raw)
    }

    private func reload() {
        notes = QuickNote.records(inVaultAt: Vault.defaultRoot())
        if selectedID == nil { selectedID = notes.first?.id }
        if let selected { draft = body(of: selected) }
        refresh()
    }

    private func save(_ note: QuickNote.Record) {
        do {
            try QuickNote.updateBody(note, body: draft)
            editing = false
            status = L("Saved")
            reload()
        } catch {
            status = error.localizedDescription
        }
    }
}

@MainActor
private struct BrainInboxNoteView: View {
    @Environment(\.dismiss) private var dismiss
    let record: QuickNote.Record
    let proposeMemory: (String) -> Void
    let retryTranscription: () -> Void
    let markReviewed: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L("Inbox"), systemImage: "tray.full").font(.headline)
                Spacer()
                Button(L("Propose memory")) {
                    proposeMemory(QuickNote.body(from: text))
                }
                .buttonStyle(.borderedProminent)
                if record.state == .needsTranscription {
                    Button(L("Transcribe now")) { retryTranscription() }
                        .buttonStyle(.borderedProminent)
                }
                Button(L("Mark as reviewed")) { markReviewed() }
                Button(L("Open original")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: record.sourcePath ?? record.path))
                }
                Button(L("Close")) { dismiss() }
            }
            .padding(16)
            Divider()
            ScrollView {
                MarkdownBody(text: QuickNote.body(from: text), follow: { _ in })
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 700, height: 520)
        .onAppear { text = (try? String(contentsOfFile: record.path, encoding: .utf8)) ?? record.excerpt }
    }
}

@MainActor
private struct BrainMissionView: View {
    @Environment(\.dismiss) private var dismiss
    let mission: Mission
    let run: (@escaping @Sendable @MainActor (MissionReceipt) -> Void) -> Void
    let cancel: () -> Void
    @State private var isRunning = false
    @State private var receipt: MissionReceipt?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(receipt == nil ? L("Mission plan") : L("Mission receipt"))
                        .font(.headline)
                    Text(receipt == nil
                         ? L("Review what the Brain is about to prepare.")
                         : L("This is what actually happened."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            if let receipt {
                ScrollView {
                    Text(receipt.render())
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            } else {
                ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(mission.intent).font(.system(size: 15, weight: .semibold))
                    ForEach(Array(mission.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text(String(index + 1)).font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(step.title).font(.system(size: 12.5, weight: .medium))
                                Text(step.action.receiptLine).font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack {
                Text(receipt == nil
                     ? (isRunning ? L("Running…") : L("Nothing runs until you choose Run."))
                     : L("The receipt is saved in your Brain and can be searched later."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if receipt != nil {
                    Button(L("Close")) { dismiss() }
                } else {
                    Button(L("Cancel")) {
                        if isRunning {
                            cancel()
                            isRunning = false
                        } else {
                            dismiss()
                        }
                    }
                    Button(L("Run mission")) {
                        isRunning = true
                        run { result in
                            receipt = result
                            isRunning = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning)
                }
            }
            .padding(14)
        }
        .frame(width: 560, height: 420)
    }
}

@MainActor
private struct BrainNoteComposer: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    let save: (String) -> Void

    init(initialText: String, save: @escaping (String) -> Void) {
        _text = State(initialValue: initialText)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "note.text").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("New Brain note")).font(.headline)
                    Text(L("Edit before saving it to your inbox.")).font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            TextEditor(text: $text)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(16)
            Divider()
            HStack {
                Text(L("Saved as Markdown in inbox")).font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("Cancel")) { dismiss() }
                Button(L("Save note")) { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 620, height: 460)
    }

    private func commit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        save(value)
        dismiss()
    }
}

// MARK: - BeBrain rail

private struct BeBrainVerb: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let phrase: String?

    static var all: [BeBrainVerb] {
        [
            .init(id: "find", title: L("Find"),
                  subtitle: L("Anything on your Mac, before you finish typing."),
                  symbol: "magnifyingglass", phrase: ""),
            .init(id: "ask", title: L("Ask"),
                  subtitle: L("Ask your own memory, not a generic model."),
                  symbol: "text.bubble", phrase: L("what do we know about ")),
            .init(id: "remember", title: L("Remember"),
                  subtitle: L("Save what matters as a commit, not a dump."),
                  symbol: "checkmark.seal", phrase: L("remember that ")),
            .init(id: "prepare", title: L("Prepare"),
                  subtitle: L("Arrive with the context already gathered."),
                  symbol: "person.2", phrase: L("prepare me for ")),
            .init(id: "decide", title: L("Decide"),
                  subtitle: L("Bring back only what is still in force."),
                  symbol: "arrow.triangle.branch", phrase: L("what did we decide about ")),
            .init(id: "act", title: L("Act"),
                  subtitle: L("Run the mission: plan, approval and receipt."),
                  symbol: "bolt.horizontal", phrase: "/"),
            .init(id: "pulse", title: L("Pulse"),
                  subtitle: L("The one that asks instead of answering."),
                  symbol: "waveform.path.ecg", phrase: L("pulse")),
        ]
    }
}

@MainActor
private struct VerbRail: View {
    @Bindable var model: GraphModel
    let selectedSurface: String
    let showOverview: () -> Void
    let showNotes: () -> Void
    let showGraph: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            railHeader
            localStatus
            VStack(spacing: 3) {
                navigationButton(L("Overview"), symbol: "square.grid.2x2",
                                 selected: selectedSurface == "overview", action: showOverview)
                navigationButton(L("My notes"), symbol: "note.text",
                                 selected: selectedSurface == "notes", action: showNotes)
                navigationButton(L("Graph"), symbol: "circle.grid.cross",
                                 selected: selectedSurface == "graph", action: showGraph)
            }
            Divider().opacity(0.35)
            VStack(spacing: 6) {
                ForEach(BeBrainVerb.all) { verb in
                    Button { run(verb) } label: { VerbRow(verb: verb) }
                        .buttonStyle(.plain)
                }
            }
            Divider().opacity(0.35)
            Spacer(minLength: 0)
            graphCommands
        }
        .padding(16)
        .background(LinearGradient(
            colors: [Color.white.opacity(0.055), Color.white.opacity(0.025)],
            startPoint: .top, endPoint: .bottom
        ))
    }

    private var railHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                BeLauncherMark(side: 20)
                Text("BeBrain").font(.system(size: 16, weight: .semibold))
            }
            Text(L("Your private memory for finding, understanding and doing."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var localStatus: some View {
        HStack(alignment: .top, spacing: 9) {
            ZStack {
                Circle().fill(Color.green.opacity(0.16))
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Private on this Mac"))
                    .font(.system(size: 11.5, weight: .semibold))
                Text(L("%@ things · %@ connections",
                       String(model.web.nodes.count), String(model.web.links.count)))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(.white.opacity(0.07)))
    }

    private var graphCommands: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                model.showRecent()
            } label: {
                RailCommand(symbol: "clock.arrow.circlepath", title: L("Recent work"),
                            value: L("last 7 days"))
            }
            .buttonStyle(.plain)
            Button {
                model.showEverything()
            } label: {
                RailCommand(symbol: "point.3.connected.trianglepath.dotted", title: L("Full graph"),
                            value: L("%1$@ nodes · %2$@ relations",
                                     String(model.web.nodes.count), String(model.web.links.count)))
            }
            .buttonStyle(.plain)
        }
    }

    private func run(_ verb: BeBrainVerb) {
        if let phrase = verb.phrase { model.primeLauncher(phrase) }
    }

    private func navigationButton(_ title: String, symbol: String, selected: Bool,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .background(selected ? Theme.accent.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

private struct VerbRow: View {
    let verb: BeBrainVerb

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: verb.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.cyan)
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verb.title).font(.system(size: 12.5, weight: .semibold))
                Text(verb.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .contentShape(Rectangle())
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.055)))
    }
}

private struct RailCommand: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11.5, weight: .medium))
                Text(value).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct TruthLadder: View {
    let compact: Bool

    private var levels: [(String, String)] {
        [
            (L("Evidence"), L("What happened, as-is.")),
            (L("Extracted Memory"), L("Distilled, not confirmed yet.")),
            (L("Committed Memory"), L("What you confirm as true.")),
            (L("Outcome Memory"), L("Truth closed by the result.")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 9) {
            Text(L("Four levels of truth"))
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                HStack(alignment: .top, spacing: 8) {
                    Text(String(index + 1))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.65))
                        .frame(width: 18, height: 18)
                        .background(Theme.cyan.opacity(0.85), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(level.0).font(.system(size: compact ? 11 : 12, weight: .semibold))
                        Text(level.1).font(.system(size: compact ? 9.5 : 10.5)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(11)
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.055)))
    }
}

private struct CaptureRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Theme.cyan.opacity(0.75)).frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

/// The window's background. Dark and quiet, so the graph is the only thing with colour in it.
private struct Backdrop: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.11),
                                Color(red: 0.03, green: 0.04, blue: 0.07)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
        .ignoresSafeArea()
    }
}

// MARK: - The pane that makes it correctable

/// What is under the selected node, and everything you can tell the brain about it.
@MainActor
private struct Inspector: View {
    @Bindable var model: GraphModel
    let read: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let node = model.selectedNode {
                    heading(node)
                    Text(model.why(node.id))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let proposal = model.proposal { merge(proposal) }
                    actions(node)
                    evidence(node.id)
                    if let document = model.readableDocument(node.id) { reading(document) }
                    if let episode = model.episode(node.id) { contents(episode) }
                    aliases(node.id)
                    neighbours(node.id)
                } else {
                    emptyInspector
                }
            }
            .padding(16)
        }
    }

    private var emptyInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Pick something in the graph"))
                    .font(.system(size: 16, weight: .semibold))
                Text(L("Every node can be opened, read, marked important, forgotten or corrected. The point is not to admire the graph; it is to keep the brain honest."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TruthLadder(compact: false)
            VStack(alignment: .leading, spacing: 8) {
                Text(L("BeBrain captures"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                CaptureRow(text: L("Pages you visit"))
                CaptureRow(text: L("Documents you edit"))
                CaptureRow(text: L("Code you write"))
                CaptureRow(text: L("What you copy and paste"))
                CaptureRow(text: L("Meetings, if you turn them on"))
            }
            .padding(11)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func heading(_ node: GraphLayout.Placed) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(node.label)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Tag(text: node.shape.label)
                Tag(text: stamp(node.at))
                if model.document(node.id)?.corrections.editedByHand == true {
                    Tag(text: L("written by you"), tone: .mine)
                }
            }
        }
    }

    private func merge(_ proposal: MergeProposal) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(proposal.question)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(L("Yes, they are the same")) { model.confirmMerge() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button(L("No")) { model.rejectMerge() }.controlSize(.small)
            }
            Text(L("A “no” is remembered for good: I will not ask again."))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(11)
        .background(Theme.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func actions(_ node: GraphLayout.Placed) -> some View {
        let pinned = model.document(node.id)?.corrections.pinned == true
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                if model.hasSource(node.id) {
                    Button { model.openSource() } label: {
                        Label(L("Open source"), systemImage: "arrow.up.right.square")
                    }
                    .controlSize(.small)
                }
                Button { model.readHere() } label: {
                    Label(L("Read here"), systemImage: "text.alignleft")
                }
                .controlSize(.small)
                Button { read() } label: {
                    Label(L("Open brain file"), systemImage: "doc.text")
                }
                .controlSize(.small)
            }
            HStack(spacing: 7) {
                Button(pinned ? L("Unmark important") : L("Mark important")) {
                    model.markImportant(!pinned)
                }
                .controlSize(.small)
                Button(L("Forget")) { model.forget() }
                    .controlSize(.small).tint(Theme.destructive)
            }
        }
    }

    private func reading(_ document: CorpusDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(L("READING"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if document.corrections.editedByHand {
                    Tag(text: L("written by you"), tone: .mine)
                }
            }
            MarkdownBody(text: document.body) { name in
                if let target = model.document(named: name) {
                    model.selected = target.id
                    model.compared = nil
                    model.proposal = nil
                } else {
                    model.status = L("“%@” has no entry of its own yet.", name)
                }
            }
            .font(.system(size: 11.5))
        }
        .padding(11)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func evidence(_ id: String) -> some View {
        let items = model.evidence(for: id)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text(L("EVIDENCE"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                ForEach(items.prefix(5)) { item in
                    EvidenceRow(item: item)
                }
            }
            .padding(11)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func contents(_ episode: Episode) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("WHAT YOU TOUCHED")).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
            ForEach(Array(episode.signals.prefix(10).enumerated()), id: \.offset) { _, signal in
                Text("\(clock(signal.at)) · \(signal.title)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            if episode.signals.count > 10 {
                Text(L("and %@ more", String(episode.signals.count - 10)))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func aliases(_ id: String) -> some View {
        let names = (model.entity(for: id)?.aliases ?? []).sorted()
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(L("ALSO CALLED"))
                    .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
                ForEach(names, id: \.self) { alias in
                    HStack(spacing: 6) {
                        Text(alias).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Separar") { model.separate(alias: alias) }
                            .buttonStyle(.link).font(.system(size: 10))
                            .help(L("These were not the same thing: give it its own entry back."))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func neighbours(_ id: String) -> some View {
        let around = model.neighbours(of: id)
        if !around.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(L("CONNECTED WITH"))
                    .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
                ForEach(around.prefix(12)) { node in
                    Button {
                        model.selected = node.id
                        model.compared = nil
                        model.proposal = nil
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Color.white.opacity(0.5)).frame(width: 5, height: 5)
                            Text(node.label).font(.system(size: 11)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    private func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private struct EvidenceRow: View {
    let item: GraphModel.Evidence

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Tag(text: item.passage.source.kind.label)
                Text(item.route.label)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(stamp(item.passage.occurredAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Text(item.passage.title)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.passage.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .clipped()
        .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter.string(from: date)
    }
}

/// So the reader can be presented as a sheet keyed on the model itself.
extension CorpusReaderModel: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
