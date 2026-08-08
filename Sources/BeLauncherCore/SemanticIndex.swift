import Foundation

/// What the index holds, and where each passage came from.
///
/// The point of naming the source is that retrieval has to be able to walk back out of a passage
/// into the graph: a hit inside a meeting note should be able to reach the people who were in that
/// meeting, and a hit on a decision should be able to reach the project it belongs to. A passage
/// with no home is a search result; a passage that knows its home is a memory.
public struct IndexedSource: Sendable, Equatable, Hashable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable, CaseIterable {
        /// A committed or proposed object from the vault.
        case memory
        /// A node from the work graph: a file, a meeting, a person, an app.
        case node
        /// Something that passed through the clipboard.
        case clip
        /// A note written from the launcher.
        case note
        /// Something asked to an assistant, and what it answered. The reasoning behind a piece of
        /// work lives here and almost never in the file it produced.
        case conversation

        public var label: String {
            switch self {
            case .memory: L("Memory")
            case .node: L("Work")
            case .clip: L("Clipboard")
            case .note: L("Note")
            case .conversation: L("Conversation")
            }
        }
    }

    public let kind: Kind
    public let id: String

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// A single column, so a passage can be found by its source in one indexed lookup.
    public var key: String { kind.rawValue + ":" + id }

    public static func key(_ raw: String) -> IndexedSource? {
        guard let separator = raw.firstIndex(of: ":"),
              let kind = Kind(rawValue: String(raw[raw.startIndex..<separator])) else { return nil }
        return IndexedSource(kind: kind, id: String(raw[raw.index(after: separator)...]))
    }
}

/// One retrievable passage.
public struct IndexedPassage: Sendable, Equatable, Identifiable {
    public let id: String
    public let source: IndexedSource
    /// What the passage is part of, so a citation can say "in the Acme meeting" rather than
    /// quoting a paragraph from nowhere.
    public let title: String
    public let ordinal: Int
    public let text: String
    public let occurredAt: Date
    /// Whether a vector was stored for it. False means this passage can only be found by word.
    public let hasVector: Bool

    /// The longest a title may be. A title is a label — "the Acme meeting", "auth.swift" — so a
    /// person reading a citation knows where the quote came from.
    ///
    /// Enforced rather than assumed, because assuming it cost 13 GB. Titles are built from captured
    /// signals, and a signal's title is whatever the capture layer saw: a page name usually, a
    /// megabyte of pasted text occasionally. That title is then written onto *every passage of its
    /// source*, so one episode with a 960 KB title and 3,439 passages stored 3.3 GB — for a single
    /// afternoon's work. Measured on a real brain: 19,413 passages holding 14 MB of text and
    /// **10.3 GB of titles**, in a database file that had grown to 13 GB and filled the disk.
    ///
    /// The cap lives here, at the one door everything goes through, rather than at each of the
    /// places that build a title. Capping it at the sources means the next capture source added
    /// gets it wrong again, and the weakest copy of a rule is the one that decides.
    public static let titleLimit = 160

    /// A title cut to a label, keeping whole words where it can and saying that it was cut.
    public static func label(_ title: String) -> String {
        let clean = title.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard clean.count > titleLimit else { return clean }
        let head = clean.prefix(titleLimit)
        // Back up to the last space so a citation does not end mid-word, unless there is no space
        // in range — a pasted URL or a wall of text without one.
        let cut = head.lastIndex(of: " ").map { head[head.startIndex..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    public init(id: String, source: IndexedSource, title: String, ordinal: Int,
                text: String, occurredAt: Date, hasVector: Bool = false) {
        self.id = id
        self.source = source
        self.title = title
        self.ordinal = ordinal
        self.text = text
        self.occurredAt = occurredAt
        self.hasVector = hasVector
    }
}

/// A retrieved passage with the reason it surfaced.
public struct Retrieved: Sendable, Equatable, Identifiable {
    public enum Route: String, Sendable, Equatable {
        /// The vector said it means the same thing.
        case meaning
        /// The words matched.
        case words
        /// Both did, which is the strongest signal there is.
        case both
        /// Neither: it came in because it is attached to something that did.
        case related
    }

    public var id: String { passage.id }
    public let passage: IndexedPassage
    public let score: Double
    public let route: Route
    /// Present on `.related` hits: the passage that pulled this one in.
    public let via: String?

    public init(passage: IndexedPassage, score: Double, route: Route, via: String? = nil) {
        self.passage = passage
        self.score = score
        self.route = route
        self.via = via
    }
}

extension Store {

    // MARK: - Schema

    /// Set up separately from the main migration so the index can be dropped and rebuilt without
    /// touching anything else. It is derived data — every passage in here exists somewhere else,
    /// which is what makes deleting it safe and re-indexing from scratch a supported operation.
    public func migrateSemanticIndex(repairOversizedTitles: Bool = true) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS passages (
                id TEXT PRIMARY KEY,
                source_key TEXT NOT NULL,
                source_kind TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                ordinal INTEGER NOT NULL DEFAULT 0,
                text TEXT NOT NULL,
                occurred_at REAL NOT NULL,
                digest TEXT NOT NULL,
                -- Base64 rather than a raw BLOB: the SQLite wrapper this app uses binds text,
                -- integers and doubles, and adding blob binding for one column would mean
                -- touching the layer every other table depends on. The cost is a third more
                -- bytes on a few thousand rows, which is nothing next to that risk.
                vector TEXT,
                vector_model TEXT NOT NULL DEFAULT ''
            )
            """)
        try database.execute("CREATE INDEX IF NOT EXISTS passages_source ON passages (source_key)")
        try database.execute("CREATE INDEX IF NOT EXISTS passages_kind ON passages (source_kind)")
        // What the embedding pass walks. Without it that query is a full scan plus a full sort,
        // once per batch, on the main thread. See `passagesNeedingVectors`.
        try database.execute("CREATE INDEX IF NOT EXISTS passages_when ON passages (occurred_at DESC)")

        // FTS5 with unicode61 and diacritic folding: "reunion" has to find "reunión", because
        // nobody types accents into a launcher.
        try database.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS passages_fts USING fts5(
                text, title,
                content='passages', content_rowid='rowid',
                tokenize="unicode61 remove_diacritics 2"
            )
            """)
        // The triggers keep the word index honest without any code remembering to.
        try database.execute("""
            CREATE TRIGGER IF NOT EXISTS passages_ai AFTER INSERT ON passages BEGIN
                INSERT INTO passages_fts(rowid, text, title) VALUES (new.rowid, new.text, new.title);
            END
            """)
        try database.execute("""
            CREATE TRIGGER IF NOT EXISTS passages_ad AFTER DELETE ON passages BEGIN
                INSERT INTO passages_fts(passages_fts, rowid, text, title)
                VALUES ('delete', old.rowid, old.text, old.title);
            END
            """)
        try database.execute("""
            CREATE TRIGGER IF NOT EXISTS passages_au AFTER UPDATE ON passages BEGIN
                INSERT INTO passages_fts(passages_fts, rowid, text, title)
                VALUES ('delete', old.rowid, old.text, old.title);
                INSERT INTO passages_fts(rowid, text, title) VALUES (new.rowid, new.text, new.title);
            END
            """)

        // Title repair is a one-time maintenance sweep over every passage. It belongs to an
        // explicit maintenance path, never to launcher startup or a normal reindex.
        if repairOversizedTitles {
            trimOversizedTitles()
        }
    }

    /// Cuts titles that were written before there was a cap on them.
    ///
    /// The cap in `replacePassages` only protects what gets written from now on, and that is not
    /// enough on its own: a source whose content has not changed is deliberately never rewritten —
    /// its digest matches, so re-cutting and re-embedding it is skipped. That is the right
    /// behaviour and it means an oversized title, once stored, would stay stored forever. Someone
    /// upgrading would keep their thirteen gigabytes and never find out why.
    ///
    /// So the repair happens once, here, where every launch already passes. It is a single UPDATE
    /// over the rows that are actually oversized; on a healthy brain it matches nothing and costs
    /// one indexless pass over a small table.
    ///
    /// Note what it does *not* do: the file does not shrink. SQLite keeps the freed pages and
    /// reuses them, so the brain stops growing but a database already at thirteen gigabytes stays
    /// that size on disk until it is compacted. Compacting needs room for a second copy, which is
    /// exactly what a person in this situation does not have, so it is a deliberate action with a
    /// button rather than something that happens behind them at launch.
    private func trimOversizedTitles() {
        let oversized = (try? database.query(
            "SELECT count(*) AS n FROM passages WHERE length(title) > ?",
            [.int(Int64(IndexedPassage.titleLimit))]))?.first?.int("n") ?? 0
        guard oversized > 0 else { return }

        try? database.execute("""
            UPDATE passages SET title = rtrim(substr(title, 1, ?)) || '…'
            WHERE length(title) > ?
            """, [.int(Int64(IndexedPassage.titleLimit)), .int(Int64(IndexedPassage.titleLimit))])
        // The word index carries the titles too, and it grew with them: on the brain that prompted
        // this, 448,487 index blocks for 19,413 documents. Rebuilding from the now-small titles
        // took it to 1,437.
        try? database.execute("INSERT INTO passages_fts(passages_fts) VALUES('rebuild')")
    }

    // MARK: - How much room it takes

    /// What the database occupies on disk, in bytes.
    ///
    /// The write-ahead log counts. In WAL mode everything written since the last checkpoint lives
    /// in `-wal`, so measuring only the main file reports 4 KB for a database holding megabytes —
    /// which is how a size check ends up reassuring somebody about a disk that is filling up.
    public var fileSize: Int {
        [path, path + "-wal", path + "-shm"].reduce(0) { total, file in
            total + (((try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? Int) ?? 0)
        }
    }

    /// Roughly what the contents actually need, from SQLite's own page accounting.
    ///
    /// Pages in use rather than bytes of text: a healthy database is legitimately larger than the
    /// sum of its strings, and comparing against the strings would call every normal brain bloated.
    public var contentSize: Int {
        let pages = (try? database.query("SELECT * FROM pragma_page_count()"))?
            .first?.int("page_count") ?? 0
        let free = (try? database.query("SELECT * FROM pragma_freelist_count()"))?
            .first?.int("freelist_count") ?? 0
        let size = (try? database.query("SELECT * FROM pragma_page_size()"))?
            .first?.int("page_size") ?? 4096
        return Int(max(0, pages - free) * size)
    }

    public enum CompactionFailure: LocalizedError {
        case notEnoughRoom(needed: Int)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notEnoughRoom(let needed):
                L("There is not enough free disk. It needs about %@ for the new copy.",
                  ByteCountFormatter.string(fromByteCount: Int64(needed), countStyle: .file))
            case .failed(let reason): reason
            }
        }
    }

    /// Rewrites the database compactly and returns how many bytes came back.
    ///
    /// Plain `VACUUM`, in place. SQLite rebuilds into a temporary file and swaps atomically, so the
    /// open connection stays valid and a failure halfway through costs nothing — which is why this
    /// is preferable to writing a copy and juggling the files here, where a mistake loses somebody
    /// their brain.
    ///
    /// The room it needs is the size of the *compacted* result, not of the bloated file, because
    /// what SQLite builds is the compacted one. That distinction is the whole reason this can help
    /// somebody whose disk is already full: the trim runs first at migration and makes the answer
    /// small, and only then is there any point compacting.
    ///
    /// The free-space check exists because running out mid-VACUUM is how a full disk became a
    /// completely full disk while trying to fix it.
    @discardableResult
    public func compact() throws -> Int {
        let before = fileSize
        let needed = Int(Double(contentSize) * 1.3) + 50_000_000
        let free = (try? FileManager.default.attributesOfFileSystem(forPath: path))?[.systemFreeSize] as? Int ?? 0
        guard free > needed else { throw CompactionFailure.notEnoughRoom(needed: needed) }

        do {
            try database.execute("PRAGMA temp_store = MEMORY")
            try database.execute("VACUUM")
        } catch {
            throw CompactionFailure.failed(String(describing: error))
        }
        return max(0, before - fileSize)
    }

    // MARK: - Writing

    /// Replaces every passage belonging to one source.
    ///
    /// Whole-source replacement rather than per-passage patching: when a note is edited its
    /// paragraphs shift, so passage 3 is no longer the old passage 3. Trying to match them up is
    /// guesswork, and getting it wrong leaves orphan passages quoting text that no longer exists.
    public func replacePassages(for source: IndexedSource, title: String, occurredAt: Date,
                                text: String) -> [IndexedPassage] {
        let cut = Semantic.passages(of: text)
        let title = IndexedPassage.label(title)
        let digest = Semantic.digest(text)

        // Unchanged content keeps its vectors: re-embedding an untouched note on every index pass
        // would make indexing cost grow with the size of the brain rather than with what changed.
        if let existing = try? database.query(
            "SELECT digest FROM passages WHERE source_key = ? LIMIT 1", [.text(source.key)]),
           existing.first?.string("digest") == digest, !cut.isEmpty {
            return passages(for: source)
        }

        try? database.execute("DELETE FROM passages WHERE source_key = ?", [.text(source.key)])
        var result: [IndexedPassage] = []
        for passage in cut {
            let id = "\(source.key)#\(passage.ordinal)"
            try? database.execute("""
                INSERT INTO passages (id, source_key, source_kind, title, ordinal, text,
                                      occurred_at, digest, vector, vector_model)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, '')
                """, [.text(id), .text(source.key), .text(source.kind.rawValue), .text(title),
                      .int(Int64(passage.ordinal)), .text(passage.text),
                      .double(occurredAt.timeIntervalSince1970), .text(digest)])
            result.append(IndexedPassage(id: id, source: source, title: title,
                                         ordinal: passage.ordinal, text: passage.text,
                                         occurredAt: occurredAt))
        }
        return result
    }

    public func removePassages(for source: IndexedSource) {
        try? database.execute("DELETE FROM passages WHERE source_key = ?", [.text(source.key)])
    }

    public func storeVector(_ vector: [Float], for passageID: String, model: String) {
        guard !vector.isEmpty else { return }
        try? database.execute(
            "UPDATE passages SET vector = ?, vector_model = ? WHERE id = ?",
            [.text(Semantic.encode(vector).base64EncodedString()), .text(model), .text(passageID)])
    }

    /// Passages still waiting for a vector, newest content first.
    ///
    /// Changing the embedding model invalidates every vector: two models put the same sentence in
    /// completely different places, and comparing across them produces confident nonsense.
    ///
    /// The two details in this query are the difference between a launcher and a beachball. It
    /// used to be `SELECT *` with no index behind it, which on a real brain — 11,256 passages,
    /// 12.5 MB of vectors — planned as `SCAN passages` plus a temp B-tree to sort all of them
    /// before taking sixty-four. That is 6.8 seconds per batch, `SELECT *` dragging in every
    /// base64 vector only to throw it away, and the embedding pass runs it once per batch until
    /// the brain is full. With nine thousand passages pending that is a quarter of an hour of
    /// frozen window, which is exactly what it looked like.
    ///
    /// So: only the columns needed to embed, and an index on `occurred_at` so SQLite walks in
    /// order and stops at sixty-four instead of sorting the table. Measured on that same brain:
    /// 6.775 s → 0.031 s.
    public func passagesNeedingVectors(model: String, limit: Int = 64) -> [IndexedPassage] {
        let rows = (try? database.query("""
            SELECT id, source_key, title, ordinal, text, occurred_at FROM passages
            WHERE vector IS NULL OR vector_model <> ?
            ORDER BY occurred_at DESC LIMIT ?
            """, [.text(model), .int(Int64(limit))])) ?? []
        return rows.compactMap { row in
            guard let source = IndexedSource.key(row.string("source_key")) else { return nil }
            return IndexedPassage(
                id: row.string("id"), source: source, title: row.string("title"),
                ordinal: Int(row.int("ordinal")), text: row.string("text"),
                occurredAt: Date(timeIntervalSince1970: row.double("occurred_at")),
                // Not selected, and known anyway: these are the ones without a usable vector.
                hasVector: false
            )
        }
    }

    public func passages(for source: IndexedSource) -> [IndexedPassage] {
        let rows = (try? database.query(
            "SELECT * FROM passages WHERE source_key = ? ORDER BY ordinal",
            [.text(source.key)])) ?? []
        return rows.compactMap(Store.passage)
    }

    public func indexedPassageCount() -> (total: Int, vectorised: Int) {
        let rows = (try? database.query(
            "SELECT COUNT(*) AS total, COUNT(vector) AS vectorised FROM passages")) ?? []
        guard let row = rows.first else { return (0, 0) }
        return (Int(row.int("total")), Int(row.int("vectorised")))
    }

    public func clearSemanticIndex() {
        try? database.execute("DELETE FROM passages")
    }

    static func passage(_ row: Row) -> IndexedPassage? {
        guard let source = IndexedSource.key(row.string("source_key")) else { return nil }
        return IndexedPassage(
            id: row.string("id"), source: source, title: row.string("title"),
            ordinal: Int(row.int("ordinal")), text: row.string("text"),
            occurredAt: Date(timeIntervalSince1970: row.double("occurred_at")),
            hasVector: !row.string("vector").isEmpty
        )
    }

    // MARK: - Reading

    /// Every stored vector, for the brute-force scan.
    ///
    /// Brute force on purpose. An approximate index earns its keep in the millions of vectors; a
    /// personal brain holds thousands, where scanning them all is a few milliseconds and always
    /// returns the true nearest neighbours instead of usually returning them.
    func storedVectors(limit: Int = 50_000) -> [(id: String, vector: [Float])] {
        let rows = (try? database.query("""
            SELECT id, vector FROM passages WHERE vector IS NOT NULL
            ORDER BY occurred_at DESC LIMIT ?
            """, [.int(Int64(limit))])) ?? []
        return rows.compactMap { row in
            guard let data = Data(base64Encoded: row.string("vector")) else { return nil }
            let vector = Semantic.decode(data)
            return vector.isEmpty ? nil : (row.string("id"), vector)
        }
    }

    /// Passages ranked by meaning.
    public func nearest(to vector: [Float], limit: Int = 12) -> [(id: String, similarity: Float)] {
        guard !vector.isEmpty else { return [] }
        return storedVectors()
            .map { ($0.id, Semantic.similarity(vector, $0.vector)) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { (id: $0.0, similarity: $0.1) }
    }

    /// Passages ranked by word, using FTS5's BM25.
    public func matchingWords(_ query: String, limit: Int = 12) -> [String] {
        let terms = Semantic.ftsQuery(query)
        guard !terms.isEmpty else { return [] }
        let rows = (try? database.query("""
            SELECT p.id AS id FROM passages_fts f
            JOIN passages p ON p.rowid = f.rowid
            WHERE passages_fts MATCH ?
            ORDER BY bm25(passages_fts, 1.0, 2.0) LIMIT ?
            """, [.text(terms), .int(Int64(limit))])) ?? []
        return rows.map { $0.string("id") }
    }

    public func passage(id: String) -> IndexedPassage? {
        let rows = (try? database.query("SELECT * FROM passages WHERE id = ?", [.text(id)])) ?? []
        return rows.first.flatMap(Store.passage)
    }
}

extension Semantic {

    /// Turns what someone typed into something FTS5 will accept.
    ///
    /// User text goes straight into a MATCH clause, and FTS5 treats quotes, asterisks, colons and
    /// `NEAR` as syntax — so an unescaped apostrophe does not just fail to match, it throws and
    /// takes the whole keyword half of the search with it. Every token is quoted, and a trailing
    /// `*` on the last one makes the search feel live while the person is still typing.
    public static func ftsQuery(_ query: String) -> String {
        let tokens = query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 }
        guard !tokens.isEmpty else { return "" }
        var quoted = tokens.map { "\"\($0)\"" }
        quoted[quoted.count - 1] = "\"\(tokens[tokens.count - 1])\"*"
        return quoted.joined(separator: " OR ")
    }
}
