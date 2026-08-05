import Foundation

/// Everything the user owns lives here, in one local SQLite file. No network, no account.
@MainActor
public final class Store {
    public let database: Database
    public let path: String

    public init(path: String) throws {
        self.path = path
        let folder = (path as NSString).deletingLastPathComponent
        if !folder.isEmpty {
            try FileManager.default.createDirectory(
                atPath: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        database = try Database(path: path)
        try migrate()
    }

    public static func defaultPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Beacon", isDirectory: true)
        return base.appendingPathComponent("beacon.sqlite3").path
    }

    private func migrate() throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS snippets (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                keyword TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                uses INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            )
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS workflows (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                keyword TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                url_template TEXT NOT NULL,
                uses INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            )
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS clips (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                text TEXT NOT NULL,
                digest TEXT NOT NULL UNIQUE,
                source_app TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL
            )
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """)
    }

    // MARK: - Settings

    public func setting(_ key: String) -> String? {
        let rows = try? database.query("SELECT value FROM settings WHERE key = ?", [.text(key)])
        return rows?.first.map { $0.string("value") }
    }

    public func setting(_ key: String, default fallback: Bool) -> Bool {
        setting(key).map { $0 == "1" } ?? fallback
    }

    public func setting(_ key: String, default fallback: Int) -> Int {
        setting(key).flatMap(Int.init) ?? fallback
    }

    public func setSetting(_ key: String, _ value: String) {
        try? database.execute(
            "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(value)]
        )
    }

    public func setSetting(_ key: String, _ value: Bool) { setSetting(key, value ? "1" : "0") }
    public func setSetting(_ key: String, _ value: Int) { setSetting(key, String(value)) }

    // MARK: - Snippets

    public func snippets() -> [Snippet] {
        let rows = (try? database.query("SELECT * FROM snippets ORDER BY uses DESC, keyword ASC")) ?? []
        return rows.map {
            Snippet(id: $0.int("id"), keyword: $0.string("keyword"), title: $0.string("title"),
                    body: $0.string("body"), uses: Int($0.int("uses")))
        }
    }

    @discardableResult
    public func addSnippet(keyword: String, title: String, body: String) throws -> Snippet {
        let key = try Validate.keyword(keyword)
        let name = try Validate.title(title)
        let text = try Validate.snippetBody(body)
        guard snippets().allSatisfy({ $0.keyword != key }) else {
            throw ValidationError.duplicateKeyword(key)
        }
        try database.execute(
            "INSERT INTO snippets (keyword, title, body, uses, created_at) VALUES (?, ?, ?, 0, ?)",
            [.text(key), .text(name), .text(text), .double(Date.now.timeIntervalSince1970)]
        )
        return Snippet(id: database.lastInsertID, keyword: key, title: name, body: text)
    }

    public func deleteSnippet(id: Int64) {
        try? database.execute("DELETE FROM snippets WHERE id = ?", [.int(id)])
    }

    // MARK: - Workflows

    public func workflows() -> [Workflow] {
        let rows = (try? database.query("SELECT * FROM workflows ORDER BY uses DESC, keyword ASC")) ?? []
        return rows.map {
            Workflow(id: $0.int("id"), keyword: $0.string("keyword"), title: $0.string("title"),
                     urlTemplate: $0.string("url_template"), uses: Int($0.int("uses")))
        }
    }

    @discardableResult
    public func addWorkflow(keyword: String, title: String, urlTemplate: String) throws -> Workflow {
        let key = try Validate.keyword(keyword)
        let name = try Validate.title(title)
        try WorkflowURL.validateTemplate(urlTemplate)
        guard workflows().allSatisfy({ $0.keyword != key }) else {
            throw ValidationError.duplicateKeyword(key)
        }
        try database.execute(
            "INSERT INTO workflows (keyword, title, url_template, uses, created_at) VALUES (?, ?, ?, 0, ?)",
            [.text(key), .text(name), .text(urlTemplate), .double(Date.now.timeIntervalSince1970)]
        )
        return Workflow(id: database.lastInsertID, keyword: key, title: name, urlTemplate: urlTemplate)
    }

    public func deleteWorkflow(id: Int64) {
        try? database.execute("DELETE FROM workflows WHERE id = ?", [.int(id)])
    }

    public func recordUse(kind: ResultKind, id: Int64) {
        switch kind {
        case .snippet: try? database.execute("UPDATE snippets SET uses = uses + 1 WHERE id = ?", [.int(id)])
        case .workflow: try? database.execute("UPDATE workflows SET uses = uses + 1 WHERE id = ?", [.int(id)])
        case .application, .clipboard: break
        }
    }

    // MARK: - Clipboard

    public func clips(limit: Int = 200) -> [Clip] {
        let rows = (try? database.query(
            "SELECT * FROM clips ORDER BY created_at DESC LIMIT ?", [.int(Int64(limit))]
        )) ?? []
        return rows.map {
            Clip(id: $0.int("id"), text: $0.string("text"), sourceApp: $0.string("source_app"),
                 createdAt: Date(timeIntervalSince1970: $0.double("created_at")))
        }
    }

    /// Re-copying the same text moves it back to the top instead of creating a duplicate row.
    public func recordClip(text: String, sourceApp: String = "", at date: Date = .now) {
        let trimmed = String(text.prefix(20_000))
        guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let digest = Digest.sha256(trimmed)
        try? database.execute("""
            INSERT INTO clips (text, digest, source_app, created_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(digest) DO UPDATE SET created_at = excluded.created_at
            """, [.text(trimmed), .text(digest), .text(sourceApp), .double(date.timeIntervalSince1970)])
    }

    public func deleteClip(id: Int64) {
        try? database.execute("DELETE FROM clips WHERE id = ?", [.int(id)])
    }

    public func clearClips() {
        try? database.execute("DELETE FROM clips")
    }

    /// Drops clips older than `retentionDays` and anything past `maxItems`.
    public func trimClips(retentionDays: Int, maxItems: Int, now: Date = .now) {
        if retentionDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400).timeIntervalSince1970
            try? database.execute("DELETE FROM clips WHERE created_at < ?", [.double(cutoff)])
        }
        if maxItems > 0 {
            try? database.execute("""
                DELETE FROM clips WHERE id NOT IN (
                    SELECT id FROM clips ORDER BY created_at DESC LIMIT ?
                )
                """, [.int(Int64(maxItems))])
        }
    }

    // MARK: - First run

    /// Seeds a handful of examples so the very first launch shows something useful.
    public func seedIfEmpty() {
        guard setting("seeded") == nil else { return }
        setSetting("seeded", true)
        _ = try? addSnippet(keyword: "sig", title: "Email signature",
                        body: "Best,\n{cursor}\n\n— sent {date:EEEE d MMMM}")
        _ = try? addSnippet(keyword: "now", title: "Timestamp", body: "{date:yyyy-MM-dd} {time}")
        _ = try? addSnippet(keyword: "uid", title: "Random UUID", body: "{uuid}")
        _ = try? addWorkflow(keyword: "gh", title: "Search GitHub",
                         urlTemplate: "https://github.com/search?q={query}")
        _ = try? addWorkflow(keyword: "w", title: "Search Wikipedia",
                         urlTemplate: "https://en.wikipedia.org/w/index.php?search={query}")
    }
}
