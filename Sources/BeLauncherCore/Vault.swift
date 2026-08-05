import Foundation

/// The Company Vault: the brain on disk.
///
/// Portable on purpose. Every object is a Markdown file with YAML front matter, in a folder the
/// user chooses — it can be a plain folder, an Obsidian vault, or a git repository. The database
/// is only an index: delete it and it rebuilds. Nothing here is a proprietary container, so
/// leaving BeLauncher costs nothing, which is the only honest way to ask someone to put their
/// company's memory in your app.
@MainActor
public final class Vault {
    public let root: String
    private let manager = FileManager.default

    public init(root: String) throws {
        self.root = root
        for folder in [objectsFolder, commitsFolder, attachmentsFolder] {
            try manager.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
    }

    public static func defaultRoot() -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeLauncher/Vault", isDirectory: true).path
    }

    var objectsFolder: String { (root as NSString).appendingPathComponent("objects") }
    var commitsFolder: String { (root as NSString).appendingPathComponent("commits") }
    var attachmentsFolder: String { (root as NSString).appendingPathComponent("attachments") }

    // MARK: - Objects

    public func save(_ object: MemoryObject) throws {
        guard !object.statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryError.emptyStatement
        }
        if let until = object.validUntil, until < object.validFrom {
            throw MemoryError.invalidValidity
        }

        // The filename carries the statement so the folder is readable, which means editing a
        // statement changes it. Without removing the old file the vault would end up with two
        // files claiming the same id, and "what is true now" would depend on directory order.
        let destination = (objectsFolder as NSString).appendingPathComponent(filename(for: object))
        if let existing = path(forID: object.id), existing != destination {
            try? manager.removeItem(atPath: existing)
        }
        try VaultDocument.render(object).write(toFile: destination, atomically: true, encoding: .utf8)
    }

    /// Finds the file holding an object, whatever its statement was when it was written.
    func path(forID id: String) -> String? {
        guard let names = try? manager.contentsOfDirectory(atPath: objectsFolder) else { return nil }
        for name in names where name.hasSuffix(".md") {
            let path = (objectsFolder as NSString).appendingPathComponent(name)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let object = VaultDocument.parse(text), object.id == id else { continue }
            return path
        }
        return nil
    }

    public func load(id: String) -> MemoryObject? {
        objects().first { $0.id == id }
    }

    public func objects() -> [MemoryObject] {
        guard let names = try? manager.contentsOfDirectory(atPath: objectsFolder) else { return [] }
        return names
            .filter { $0.hasSuffix(".md") }
            .compactMap { name in
                let path = (objectsFolder as NSString).appendingPathComponent(name)
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
                return VaultDocument.parse(text)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// What is true right now, newest first.
    public func current(kind: MemoryObject.Kind? = nil, at date: Date = .now) -> [MemoryObject] {
        objects().filter {
            $0.level == .committed && $0.isCurrent(at: date) && (kind == nil || $0.kind == kind)
        }
    }

    public func delete(id: String) {
        guard let path = path(forID: id) else { return }
        try? manager.removeItem(atPath: path)
    }

    private func filename(for object: MemoryObject) -> String {
        let stamp = ISO8601DateFormatter.vaultStamp().string(from: object.createdAt)
        let slug = Importers.slug(String(object.statement.prefix(50)))
        return SafeFilename.make("\(stamp)-\(slug.isEmpty ? object.kind.rawValue : slug)-\(object.id.prefix(8))",
                                 extension: "md")
    }

    // MARK: - Commits

    public func save(_ commit: MemoryCommit) throws {
        let path = (commitsFolder as NSString).appendingPathComponent("\(commit.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(commit).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public func commits(state: MemoryCommit.State? = nil) -> [MemoryCommit] {
        guard let names = try? manager.contentsOfDirectory(atPath: commitsFolder) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name in
                let path = (commitsFolder as NSString).appendingPathComponent(name)
                guard let data = manager.contents(atPath: path) else { return nil }
                return try? decoder.decode(MemoryCommit.self, from: data)
            }
            .filter { state == nil || $0.state == state }
            .sorted { $0.proposedAt > $1.proposedAt }
    }

    /// Proposes a change. Conflicts are worked out now, so the person deciding sees what this
    /// would replace before they say yes.
    @discardableResult
    public func propose(_ object: MemoryObject, reason: String = "") throws -> MemoryCommit {
        guard !object.statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryError.emptyStatement
        }
        let conflicts = current(kind: object.kind)
            .filter { $0.id != object.id && overlaps($0, object) }
            .map(\.id)

        let commit = MemoryCommit(object: object, reason: reason, conflicts: conflicts)
        try save(commit)
        return commit
    }

    /// Applies a commit: writes the object and retires whatever it replaced, both directions of
    /// the link recorded so history stays walkable.
    @discardableResult
    public func confirm(commitID: String, at date: Date = .now) throws -> MemoryObject {
        guard let commit = commits().first(where: { $0.id == commitID }) else {
            throw MemoryError.unknownCommit(commitID)
        }
        guard commit.state == .proposed else { throw MemoryError.notProposed }

        var object = commit.object
        object.level = .committed
        object.supersedes = commit.conflicts

        for conflictID in commit.conflicts {
            guard var previous = load(id: conflictID) else { continue }
            previous.status = .superseded
            previous.supersededBy = object.id
            previous.validUntil = date
            try save(previous)
        }
        try save(object)

        var decided = commit
        decided.state = .confirmed
        decided.decidedAt = date
        try save(decided)
        return object
    }

    public func discard(commitID: String, at date: Date = .now) throws {
        guard var commit = commits().first(where: { $0.id == commitID }) else {
            throw MemoryError.unknownCommit(commitID)
        }
        guard commit.state == .proposed else { throw MemoryError.notProposed }
        commit.state = .discarded
        commit.decidedAt = date
        try save(commit)
    }

    /// Two objects clash when they are the same kind and share an entity, or say most of the same
    /// words. This is a bag-of-words heuristic and it has real gaps: "el plan Pro cuesta 49" and
    /// "el precio del Pro es 59" contradict each other but may not trip it. It catches the common
    /// case and errs towards asking; it is not a guarantee that two contradictions cannot coexist,
    /// and the Pulse work in a later wave is what will close that.
    func overlaps(_ existing: MemoryObject, _ incoming: MemoryObject) -> Bool {
        guard existing.kind == incoming.kind else { return false }

        let existingWords = Set(significantWords(existing.statement))
        let incomingWords = Set(significantWords(incoming.statement))
        guard !existingWords.isEmpty, !incomingWords.isEmpty else { return false }
        let shared = existingWords.intersection(incomingWords).count
        let similarity = Double(shared) / Double(min(existingWords.count, incomingWords.count))

        // Sharing a topic is not enough on its own. "Precio base 1000" and "Descuento anual 10%"
        // are both decisions about pricing and both remain true; treating the second as replacing
        // the first would quietly delete a live decision, which is worse than missing a conflict.
        // A shared entity only lowers the bar for how similar the wording has to be.
        // The share marker is bookkeeping, not a subject.
        let sharedEntity = !TeamBrain.topics(of: existing).isDisjoint(with: TeamBrain.topics(of: incoming))
        return similarity >= (sharedEntity ? 0.4 : 0.7)
    }

    private func significantWords(_ text: String) -> [String] {
        let stop: Set<String> = ["el", "la", "los", "las", "de", "del", "que", "y", "a", "en",
                                 "para", "con", "un", "una", "no", "se", "es", "the", "of", "to"]
        return text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 && !stop.contains($0) }
    }
}

extension ISO8601DateFormatter {
    /// A fresh formatter each time: DateFormatter is not Sendable, and a shared one would be a
    /// data race waiting for the first background index.
    static func vaultStamp() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate]
        return formatter
    }
}
