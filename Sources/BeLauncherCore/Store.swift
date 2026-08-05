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
            .appendingPathComponent("BeLauncher", isDirectory: true)
        return base.appendingPathComponent("belauncher.sqlite3").path
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
                created_at REAL NOT NULL,
                kind TEXT NOT NULL DEFAULT 'text',
                pinned INTEGER NOT NULL DEFAULT 0,
                asset_path TEXT NOT NULL DEFAULT ''
            )
            """)
        // Columns added after the first release; ignoring the error is the migration.
        for column in ["kind TEXT NOT NULL DEFAULT 'text'",
                       "pinned INTEGER NOT NULL DEFAULT 0",
                       "asset_path TEXT NOT NULL DEFAULT ''"] {
            try? database.execute("ALTER TABLE clips ADD COLUMN \(column)")
        }
        try database.execute("""
            CREATE TABLE IF NOT EXISTS flows (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                keyword TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                steps TEXT NOT NULL,
                uses INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            )
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS launches (
                path TEXT PRIMARY KEY,
                uses INTEGER NOT NULL DEFAULT 0,
                last_used REAL NOT NULL
            )
            """)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS aliases (
                alias TEXT PRIMARY KEY,
                target TEXT NOT NULL
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

    // MARK: - Flows

    public func flows() -> [Flow] {
        let rows = (try? database.query("SELECT * FROM flows ORDER BY uses DESC, keyword ASC")) ?? []
        return rows.compactMap { row in
            guard let data = row.string("steps").data(using: .utf8),
                  let steps = try? JSONDecoder().decode([FlowStep].self, from: data) else { return nil }
            return Flow(id: row.int("id"), keyword: row.string("keyword"), title: row.string("title"),
                        steps: steps, uses: Int(row.int("uses")))
        }
    }

    @discardableResult
    public func addFlow(keyword: String, title: String, steps: [FlowStep]) throws -> Flow {
        let key = try Validate.keyword(keyword)
        let name = try Validate.title(title)
        try FlowValidator.validate(steps, snippetKeywords: Set(snippets().map(\.keyword)))
        guard flows().allSatisfy({ $0.keyword != key }) else { throw ValidationError.duplicateKeyword(key) }
        let encoded = String(decoding: try JSONEncoder().encode(steps), as: UTF8.self)
        try database.execute(
            "INSERT INTO flows (keyword, title, steps, uses, created_at) VALUES (?, ?, ?, 0, ?)",
            [.text(key), .text(name), .text(encoded), .double(Date.now.timeIntervalSince1970)]
        )
        return Flow(id: database.lastInsertID, keyword: key, title: name, steps: steps)
    }

    public func updateFlowSteps(id: Int64, steps: [FlowStep]) throws {
        try FlowValidator.validate(steps, snippetKeywords: Set(snippets().map(\.keyword)))
        let encoded = String(decoding: try JSONEncoder().encode(steps), as: UTF8.self)
        try database.execute("UPDATE flows SET steps = ? WHERE id = ?", [.text(encoded), .int(id)])
    }

    public func deleteFlow(id: Int64) {
        try? database.execute("DELETE FROM flows WHERE id = ?", [.int(id)])
    }

    // MARK: - Launch history and aliases

    /// Applications have no row of their own, so their ranking is kept by path.
    public func recordLaunch(path: String, at date: Date = .now) {
        try? database.execute("""
            INSERT INTO launches (path, uses, last_used) VALUES (?, 1, ?)
            ON CONFLICT(path) DO UPDATE SET uses = uses + 1, last_used = excluded.last_used
            """, [.text(path), .double(date.timeIntervalSince1970)])
    }

    public func applicationUses() -> [String: Int] {
        let rows = (try? database.query("SELECT path, uses FROM launches")) ?? []
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.string("path"), Int($0.int("uses"))) })
    }

    public func aliases() -> [String: String] {
        let rows = (try? database.query("SELECT alias, target FROM aliases")) ?? []
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.string("alias"), $0.string("target")) })
    }

    @discardableResult
    public func setAlias(_ alias: String, target: String) throws -> String {
        let key = try Validate.keyword(alias)
        guard !target.isEmpty else { throw ValidationError.emptyBody }
        try database.execute(
            "INSERT INTO aliases (alias, target) VALUES (?, ?) ON CONFLICT(alias) DO UPDATE SET target = excluded.target",
            [.text(key), .text(target)]
        )
        return key
    }

    public func removeAlias(_ alias: String) {
        try? database.execute("DELETE FROM aliases WHERE alias = ?", [.text(alias.lowercased())])
    }

    public func recordUse(kind: ResultKind, id: Int64) {
        switch kind {
        case .snippet: try? database.execute("UPDATE snippets SET uses = uses + 1 WHERE id = ?", [.int(id)])
        case .workflow: try? database.execute("UPDATE workflows SET uses = uses + 1 WHERE id = ?", [.int(id)])
        case .flow: try? database.execute("UPDATE flows SET uses = uses + 1 WHERE id = ?", [.int(id)])
        default: break
        }
    }

    // MARK: - Clipboard

    public func clips(limit: Int = 200) -> [Clip] {
        // Pinned first, then most recent: a pinned clip is one you want at hand, not one you
        // happened to copy last.
        let rows = (try? database.query(
            "SELECT * FROM clips ORDER BY pinned DESC, created_at DESC LIMIT ?", [.int(Int64(limit))]
        )) ?? []
        return rows.map {
            Clip(id: $0.int("id"), text: $0.string("text"), sourceApp: $0.string("source_app"),
                 createdAt: Date(timeIntervalSince1970: $0.double("created_at")),
                 kind: Clip.Kind(rawValue: $0.string("kind")) ?? .text,
                 isPinned: $0.int("pinned") == 1,
                 assetPath: $0.string("asset_path"))
        }
    }

    public func setPinned(_ pinned: Bool, clip id: Int64) {
        try? database.execute("UPDATE clips SET pinned = ? WHERE id = ?",
                              [.int(pinned ? 1 : 0), .int(id)])
    }

    /// Apps whose copies are never recorded. Password managers already mark their own, this is
    /// for everything else the user would rather keep out.
    public func excludedApps() -> Set<String> {
        Set((setting("clipboard_excluded_apps") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    public func setExcludedApps(_ apps: Set<String>) {
        setSetting("clipboard_excluded_apps", apps.sorted().joined(separator: ","))
    }

    /// Re-copying the same text moves it back to the top instead of creating a duplicate row.
    @discardableResult
    public func recordClip(text: String, sourceApp: String = "", at date: Date = .now,
                           kind: Clip.Kind? = nil, assetPath: String = "") -> Bool {
        let trimmed = String(text.prefix(20_000))
        guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // Credentials never enter the history — see SecretGuard for why this is not optional.
        guard !SecretGuard.looksLikeSecret(trimmed) else { return false }
        guard !excludedApps().contains(sourceApp.lowercased()) else { return false }

        let resolved = kind ?? Clip.detectKind(trimmed)
        let digest = Digest.sha256(trimmed)
        try? database.execute("""
            INSERT INTO clips (text, digest, source_app, created_at, kind, asset_path)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(digest) DO UPDATE SET created_at = excluded.created_at
            """, [.text(trimmed), .text(digest), .text(sourceApp),
                  .double(date.timeIntervalSince1970), .text(resolved.rawValue), .text(assetPath)])
        return true
    }

    public func deleteClip(id: Int64) {
        try? database.execute("DELETE FROM clips WHERE id = ?", [.int(id)])
    }

    public func clearClips() {
        try? database.execute("DELETE FROM clips")
    }

    /// Removes credentials that were captured before SecretGuard existed. Runs on every
    /// launch: a key already in the history is exactly the problem worth fixing.
    @discardableResult
    public func purgeSecrets() -> Int {
        let offenders = clips(limit: 100_000).filter { SecretGuard.looksLikeSecret($0.text) }
        for clip in offenders { deleteClip(id: clip.id) }
        return offenders.count
    }

    /// Drops clips older than `retentionDays` and anything past `maxItems`.
    public func trimClips(retentionDays: Int, maxItems: Int, now: Date = .now) {
        if retentionDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400).timeIntervalSince1970
            // Pinned clips are exempt: pinning is the user saying "keep this".
            try? database.execute("DELETE FROM clips WHERE pinned = 0 AND created_at < ?", [.double(cutoff)])
        }
        if maxItems > 0 {
            try? database.execute("""
                DELETE FROM clips WHERE pinned = 0 AND id NOT IN (
                    SELECT id FROM clips ORDER BY pinned DESC, created_at DESC LIMIT ?
                )
                """, [.int(Int64(maxItems))])
        }
    }

    // MARK: - First run

    /// Quick commands everyone expects on day one. Added on every launch, not just the first,
    /// so people who installed an earlier build get them too — existing keywords are never
    /// touched, so a workflow you edited stays yours.
    public func ensureQuickCommands() {
        let defaults: [(String, String, String)] = [
            ("g", "Buscar en Google", "https://www.google.com/search?q={query}"),
            ("c", "Preguntar a Claude", "https://claude.ai/new?q={query}"),
            ("gpt", "Preguntar a ChatGPT", "https://chatgpt.com/?q={query}"),
            ("p", "Preguntar a Perplexity", "https://www.perplexity.ai/search?q={query}"),
            ("yt", "Buscar en YouTube", "https://www.youtube.com/results?search_query={query}"),
        ]
        let taken = Set(workflows().map(\.keyword))
        for (keyword, title, template) in defaults where !taken.contains(keyword) {
            _ = try? addWorkflow(keyword: keyword, title: title, urlTemplate: template)
        }
    }

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
        _ = try? addFlow(keyword: "focus", title: "Modo enfoque", steps: [
            .openApp(path: "/System/Applications/Utilities/Terminal.app"),
            .timer(minutes: 50, label: "Bloque de enfoque"),
        ])
    }
}
