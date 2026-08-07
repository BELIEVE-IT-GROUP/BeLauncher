import Foundation

/// Everything the brain can be asked about, gathered from where it already lives.
///
/// The complaint this answers is the fair one: a memory that only holds what you remembered to
/// type into it is a notebook, and a notebook is not what anyone means by memory. So the index
/// pulls from four places, and only the first requires anyone to decide anything:
///
/// - **Memories** — what was committed to the vault. Deliberate, few, and the only ones treated
///   as true.
/// - **The work graph** — the files, apps, meetings and people that were captured automatically
///   from what actually happened on the Mac. Nobody types these.
/// - **The clipboard** — what passed through your hands. Already stored, never searchable by
///   meaning until now.
/// - **Notes** — what was written from the launcher in passing.
///
/// What is deliberately *not* here: reading arbitrary documents off the disk, watching windows, or
/// transcribing anything. Those are captures the app has not asked permission for, and an index
/// that quietly grows to include them is exactly the thing this product promises not to be.
public enum Indexer {

    /// One thing to index, flattened from whatever it was.
    public struct Item: Sendable, Equatable {
        public let source: IndexedSource
        public let title: String
        public let text: String
        public let occurredAt: Date

        public init(source: IndexedSource, title: String, text: String, occurredAt: Date) {
            self.source = source
            self.title = title
            self.text = text
            self.occurredAt = occurredAt
        }
    }

    /// Clips shorter than this are a word, a URL, a hex colour. They cost a vector each and
    /// answer nothing.
    public static let minimumClipCharacters = 60

    public static func items(memories: [MemoryObject]) -> [Item] {
        memories.map { memory in
            // Statement first, then body: the statement is the sentence a person would say out
            // loud, so a passage that contains it retrieves far better than one that starts
            // mid-paragraph.
            var text = memory.statement
            if !memory.body.isEmpty { text += "\n\n" + memory.body }
            if !memory.entities.isEmpty { text += "\n\n" + memory.entities.joined(separator: ", ") }
            return Item(source: IndexedSource(kind: .memory, id: memory.id),
                        title: memory.statement, text: text, occurredAt: memory.validFrom)
        }
    }

    public static func items(nodes: [WorkNode]) -> [Item] {
        nodes.compactMap { node -> Item? in
            let text = [node.name, node.detail, node.kind.label]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            // A node whose whole content is its own name adds nothing a name lookup does not
            // already do, and dilutes every vector search it appears in.
            guard text.count >= 20 else { return nil }
            return Item(source: IndexedSource(kind: .node, id: node.id),
                        title: node.name, text: text, occurredAt: node.lastSeen)
        }
    }

    public static func items(clips: [Clip]) -> [Item] {
        clips.compactMap { clip -> Item? in
            let text = clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= minimumClipCharacters else { return nil }
            // Anything the guard would refuse to store never gets a vector either. A password
            // that is unsearchable but sitting in the index is still a password sitting in the
            // index, and it would surface as a citation.
            // carriesSecret, not looksLikeSecret: the weaker rule reads the first word, so
            // "aquí está la clave sk-ant-…" was indexed happily. The exit filter was hardened
            // first and this door was left open, which only means the credential sits on disk
            // instead of leaving over the wire.
            guard !SecretGuard.carriesSecret(text) else { return nil }
            let title = String(text.prefix(60)).replacingOccurrences(of: "\n", with: " ")
            return Item(source: IndexedSource(kind: .clip, id: String(clip.id)),
                        title: title, text: text, occurredAt: clip.createdAt)
        }
    }

    public static func items(notes: [QuickNote.Record]) -> [Item] {
        notes.map { note in
            Item(source: IndexedSource(kind: .note, id: note.id), title: note.title,
                 text: note.excerpt, occurredAt: dateFromFilename(note.id))
        }
    }

    private static func dateFromFilename(_ path: String) -> Date {
        let name = (path as NSString).lastPathComponent
        let stamp = String(name.prefix(16))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.date(from: stamp) ?? .now
    }

    /// What changed, so a pass only touches what it has to.
    ///
    /// Sources that disappeared are removed rather than left behind: a memory that was deleted and
    /// still answers questions is worse than one that was never indexed, because the person
    /// deleted it on purpose.
    public static func removals(indexed: Set<String>, current: Set<String>) -> [IndexedSource] {
        indexed.subtracting(current).compactMap(IndexedSource.key)
    }
}

extension Store {

    /// Rebuilds the passage index from everything available, without touching vectors that are
    /// still valid. Cheap enough to run at launch and after anything is remembered.
    @discardableResult
    public func reindex(memories: [MemoryObject], nodes: [WorkNode], clips: [Clip],
                        notes: [QuickNote.Record] = []) -> Int {
        let items = Indexer.items(memories: memories)
            + Indexer.items(nodes: nodes)
            + Indexer.items(clips: clips)
            + Indexer.items(notes: notes)

        var written = 0
        for item in items {
            written += replacePassages(for: item.source, title: item.title,
                                       occurredAt: item.occurredAt, text: item.text).count
        }

        let present = Set(items.map(\.source.key))
        let stored = Set(((try? database.query("SELECT DISTINCT source_key FROM passages")) ?? [])
            .map { $0.string("source_key") })
        for gone in Indexer.removals(indexed: stored, current: present) {
            removePassages(for: gone)
        }
        return written
    }

    /// One hop out of a passage's source, through the work graph.
    ///
    /// Memories reach the graph through their entities: a decision naming "Acme" connects to the
    /// Acme node and from there to the meetings and people attached to it. That link is what lets
    /// a question about a person reach a commitment that never names them.
    public func relatedSources(to source: IndexedSource, limit: Int = 4) -> [IndexedSource] {
        switch source.kind {
        case .node:
            return edges(from: source.id)
                .prefix(limit)
                .map { IndexedSource(kind: .node, id: $0.target == source.id ? $0.source : $0.target) }
        case .memory:
            guard let memory = passages(for: source).first else { return [] }
            let names = Fuzzy.folded(memory.title)
            return nodes(limit: 200)
                .filter { node in
                    let folded = Fuzzy.folded(node.name)
                    return folded.count > 2 && names.contains(folded)
                }
                .prefix(limit)
                .map { IndexedSource(kind: .node, id: $0.id) }
        case .clip, .note, .conversation:
            return []
        }
    }
}
