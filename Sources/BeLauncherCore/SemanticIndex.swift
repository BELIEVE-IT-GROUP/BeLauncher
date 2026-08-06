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

        public var label: String {
            switch self {
            case .memory: "Memoria"
            case .node: "Trabajo"
            case .clip: "Portapapeles"
            case .note: "Nota"
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
    public func migrateSemanticIndex() throws {
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

    /// Passages still waiting for a vector, oldest content first.
    ///
    /// Changing the embedding model invalidates every vector: two models put the same sentence in
    /// completely different places, and comparing across them produces confident nonsense.
    public func passagesNeedingVectors(model: String, limit: Int = 64) -> [IndexedPassage] {
        let rows = (try? database.query("""
            SELECT * FROM passages
            WHERE vector IS NULL OR vector_model <> ?
            ORDER BY occurred_at DESC LIMIT ?
            """, [.text(model), .int(Int64(limit))])) ?? []
        return rows.compactMap(Store.passage)
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
