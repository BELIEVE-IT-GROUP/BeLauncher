import SwiftUI
import AppKit
import BeLauncherCore

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
            case .week: "7 días"
            case .month: "30 días"
            case .quarter: "3 meses"
            case .everything: "Todo"
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
        if documents[id]?.corrections.pinned == true { return "Lo marcaste tú como importante." }
        if let episode = episodes[id] {
            return Relevance.explain(Relevance.signals(for: episode,
                                                       neighbours: episode.subjects.count))
        }
        guard let node = workNodes[id] else { return "" }
        return node.weight > 1
            ? "Ha aparecido \(node.weight) veces en lo que haces."
            : "Ha aparecido una vez. Con eso apenas pesa."
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
            status = "Elige dos entidades para poder unirlas."
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
                ? "No veo nada que diga que «\(left.canonical)» y «\(right.canonical)» son lo mismo."
                : "Ya me dijiste que no son lo mismo. No vuelvo a preguntarlo."
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
            _ = try? corpus.save(CorpusFiles.document(for: merged, seenAt: winner.lastSeen))
            if let document = documents[loser.id] {
                _ = try? corpus.apply(.mergedInto(merged.id), to: document)
            }
        }
        status = "«\(loser.name)» ahora es un alias de «\(merged.canonical)». \(proposal.reason.explanation.prefix(1).uppercased() + proposal.reason.explanation.dropFirst())."
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
        status = "Anotado: no son lo mismo. No vuelvo a proponerlo."
        self.proposal = nil
        compared = nil
    }

    /// Pulls a name back out of an entity that swallowed it.
    func separate(alias: String) {
        guard let id = selected, let entity = entity(for: id), let corpus else { return }
        var trimmed = entity
        trimmed.aliases.remove(alias)
        let freed = Entity(kind: entity.kind, canonical: alias, weight: 1)

        _ = try? corpus.save(CorpusFiles.document(for: trimmed, seenAt: now))
        _ = try? corpus.save(CorpusFiles.document(for: freed, seenAt: now))
        // The split has to reach the engine too, or tonight's pass folds them straight back
        // together and the correction looks like it never happened.
        let undo = MergeProposal(left: trimmed.canonical, right: alias, reason: .sameName)
        rejected.insert(undo.id)
        if let document = documents[id] ?? corpus.load(id: id, kind: .entity) {
            _ = try? corpus.apply(.rejectMerge(undo), to: document)
        }
        store.upsertNode(WorkNode(id: WorkNode.identifier(kind: workKind(entity.kind), name: alias),
                                  kind: workKind(entity.kind), name: alias, lastSeen: now))
        status = "«\(alias)» vuelve a ser algo aparte."
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
            ? "Marcado. A partir de ahora pesa lo máximo en las búsquedas."
            : "Quitada la marca."
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
        status = "«\(name)» fuera del cerebro."
        selected = nil
        load()
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
        if let node = workNodes[id], !node.target.isEmpty {
            if node.target.hasPrefix("http"), let url = URL(string: node.target) {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: node.target))
            }
            status = nil
            return
        }
        status = "Esto no tiene nada que abrir fuera. Ábrelo en el lector para leerlo entero."
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
    @Bindable var model: GraphModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reader: CorpusReaderModel?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                canvas
                if model.selectedNode != nil {
                    Divider().opacity(0.4)
                    Inspector(model: model, read: openReader)
                        .frame(width: 300)
                        .transition(.move(edge: .trailing))
                }
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(minWidth: 940, minHeight: 640)
        .background(Backdrop())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.selected)
        .sheet(item: $reader) { reader in
            VStack(spacing: 0) {
                CorpusReaderView(model: reader)
                Divider()
                HStack {
                    Spacer()
                    Button("Cerrar") { self.reader = nil }.keyboardShortcut(.escape)
                }
                .padding(10)
            }
            .frame(width: 900, height: 620)
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                BeLauncherMark(side: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lo que el cerebro sabe de ti")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(model.counted) nodos · \(model.drawing.lines.count) relaciones")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Picker("", selection: $model.span) {
                ForEach(GraphModel.Span.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            .help("El tiempo es un eje de primera: esto es un grafo de cosas que pasaron.")

            Picker("", selection: $model.arrangement) {
                ForEach(GraphLayout.Arrangement.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 190)

            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: $model.floor, in: 0...0.9).frame(width: 84)
            }
            .help("Sube el listón de relevancia y se va lo que apenas pesa.")

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Filtrar", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 120)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.white.opacity(0.07), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    if model.arrangement == .timeline { drawAxis(&context, size: size) }
                    drawLines(&context)
                    drawNodes(&context)
                }
                // One Canvas rather than a view per node: a few hundred SwiftUI views laying
                // themselves out on every hover is a slideshow, and this is meant to be flown
                // through.
                .contentShape(Rectangle())
                .onTapGesture { location in
                    model.tap(x: location.x, y: location.y,
                              extending: NSEvent.modifierFlags.contains(.shift))
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        model.hovered = GraphLayout.nearest(toX: point.x, y: point.y,
                                                            in: model.drawing)?.id
                    case .ended:
                        model.hovered = nil
                    }
                }

                // Not while one is being worked out: the canvas is empty for the moment between a
                // keystroke and its picture, and "aquí no hay nada" flashing during a search reads
                // as a brain that just lost everything.
                if model.drawing.isEmpty, !model.isLaying { emptyState }
            }
            .onAppear { model.size = geometry.size }
            .onChange(of: geometry.size) { _, size in model.size = size }
        }
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { model.move(.left); return .handled }
        .onKeyPress(.rightArrow) { model.move(.right); return .handled }
        .onKeyPress(.upArrow) { model.move(.up); return .handled }
        .onKeyPress(.downArrow) { model.move(.down); return .handled }
        .onKeyPress(.return) { model.open(); return .handled }
        .onKeyPress(.space) { model.markImportant(true); return .handled }
        .onKeyPress(.delete) { model.forget(); return .handled }
        .onKeyPress(.escape) { model.selected = nil; model.compared = nil; return .handled }
        .onKeyPress(KeyEquivalent("l")) { openReader(); return .handled }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Mascot(height: 96)
            Text("Aquí no hay nada todavía")
                .font(.system(size: 15, weight: .semibold))
            Text("El grafo sale de lo que haces, no de lo que escribes. En cuanto la captura lleve un rato encendida, esto se llena solo.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Drawing

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
            if let status = model.status {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            } else if let note = model.drawing.omittedNote {
                Label(note, systemImage: "eye.slash")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    KeyCap(symbol: "↑↓←→", label: "moverte")
                    KeyCap(symbol: "⏎", label: "abrir")
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
            model.status = "No hay carpeta de corpus configurada todavía."
            return
        }
        reader = CorpusReaderModel(folder: corpus, selecting: model.selected)
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
                    if let episode = model.episode(node.id) { contents(episode) }
                    aliases(node.id)
                    neighbours(node.id)
                }
            }
            .padding(16)
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
                    Tag(text: "escrito por ti", tone: .mine)
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
                Button("Sí, son lo mismo") { model.confirmMerge() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("No") { model.rejectMerge() }.controlSize(.small)
            }
            Text("Un «no» se recuerda para siempre: no vuelvo a preguntarlo.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(11)
        .background(Theme.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func actions(_ node: GraphLayout.Placed) -> some View {
        let pinned = model.document(node.id)?.corrections.pinned == true
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Button("Abrir") { model.open() }.controlSize(.small)
                Button("Leer") { read() }.controlSize(.small)
            }
            HStack(spacing: 7) {
                Button(pinned ? "Quitar importancia" : "Marcar importante") {
                    model.markImportant(!pinned)
                }
                .controlSize(.small)
                Button("Olvidar") { model.forget() }
                    .controlSize(.small).tint(Theme.destructive)
            }
        }
    }

    private func contents(_ episode: Episode) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("QUÉ TOCASTE").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
            ForEach(Array(episode.signals.prefix(10).enumerated()), id: \.offset) { _, signal in
                Text("\(clock(signal.at)) · \(signal.title)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            if episode.signals.count > 10 {
                Text("y \(episode.signals.count - 10) más")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func aliases(_ id: String) -> some View {
        let names = (model.entity(for: id)?.aliases ?? []).sorted()
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("TAMBIÉN SE LLAMA")
                    .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
                ForEach(names, id: \.self) { alias in
                    HStack(spacing: 6) {
                        Text(alias).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Separar") { model.separate(alias: alias) }
                            .buttonStyle(.link).font(.system(size: 10))
                            .help("Esto no era lo mismo: devuélvele su ficha propia.")
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
                Text("CONECTADO CON")
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

/// So the reader can be presented as a sheet keyed on the model itself.
extension CorpusReaderModel: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
