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
    private struct StagedWrite: Codable {
        let staged: String
        let destination: String
        let previous: String?
    }

    private struct StagingManifest: Codable {
        let writes: [StagedWrite]
    }

    public let root: String
    private let manager = FileManager.default

    public init(root: String) throws {
        self.root = root
        for folder in [objectsFolder, commitsFolder, attachmentsFolder, inboxFolder, auditFolder] {
        try manager.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
        recoverStaging()
        // The rest of the structure plus a README, so the first time someone opens this folder it
        // explains what goes where instead of showing them two folders called objects and commits.
        try? VaultGuide.scaffold(at: root, manager: manager)
    }

    public static func defaultRoot() -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeLauncher/Vault", isDirectory: true).path
    }

    /// Raw recordings are attachments, not a second memory store beside the vault.
    public static func recordingsRoot() -> URL {
        URL(fileURLWithPath: defaultRoot()).appendingPathComponent("attachments/recordings",
                                                                    isDirectory: true)
    }

    var objectsFolder: String { (root as NSString).appendingPathComponent("objects") }
    var commitsFolder: String { (root as NSString).appendingPathComponent("commits") }
    var attachmentsFolder: String { (root as NSString).appendingPathComponent("attachments") }
    var inboxFolder: String { (root as NSString).appendingPathComponent("inbox") }
    var auditFolder: String { (root as NSString).appendingPathComponent("audit") }

    /// Records AI control-plane activity without storing prompts, answers or memory contents.
    /// The audit file is local, append-only in normal operation, and readable as ordinary JSONL.
    public func recordAIAudit(_ event: BELAIAuditEvent) throws {
        let url = URL(fileURLWithPath: (auditFolder as NSString)
            .appendingPathComponent("ai.jsonl"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let line = try encoder.encode(event) + Data([0x0A])
        let previous = (try? Data(contentsOf: url)) ?? Data()
        try (previous + line).write(to: url, options: .atomic)
    }

    public func aiAuditEvents() -> [BELAIAuditEvent] {
        let path = (auditFolder as NSString).appendingPathComponent("ai.jsonl")
        guard let data = manager.contents(atPath: path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap {
            try? decoder.decode(BELAIAuditEvent.self, from: Data($0))
        }
    }

    /// Publishes human-readable evidence through the same durable manifest as memory objects.
    /// Evidence is intentionally still an ordinary Inbox Markdown file; the manifest only makes
    /// its appearance recoverable if the app exits between staging and publication.
    @discardableResult
    public func saveEvidence(title: String, text: String, at date: Date = .now,
                             sourcePath: String? = nil,
                             attachmentURL: URL? = nil) throws -> String {
        let filename = QuickNote.filename(for: "\(title) \(text.prefix(80))", at: date)
        let destination = (inboxFolder as NSString).appendingPathComponent(filename)
        let attachmentDestination = try attachmentURL.map { try stageableAttachmentPath(for: $0, title: title, at: date) }
        var writes = [
            StagedWriteInput(destination: destination,
                             data: Data(QuickNote.renderEvidence(title: title,
                                                                  text: text,
                                                                  at: date,
                                                                  sourcePath: sourcePath,
                                                                  attachmentPath: attachmentDestination).utf8),
                             previous: manager.fileExists(atPath: destination)
                                ? destination : nil)
        ]
        if let attachmentURL, let attachmentDestination {
            writes.append(StagedWriteInput(destination: attachmentDestination,
                                           payload: .file(attachmentURL),
                                           previous: manager.fileExists(atPath: attachmentDestination)
                                                ? attachmentDestination : nil))
        }
        try writeFiles(writes)
        return destination
    }

    @discardableResult
    public func saveQuickNote(_ text: String, at date: Date = .now) throws -> String {
        let destination = (inboxFolder as NSString)
            .appendingPathComponent(QuickNote.filename(for: text, at: date))
        try writeFiles([StagedWriteInput(destination: destination,
                                         data: Data(QuickNote.render(text, at: date).utf8),
                                         previous: manager.fileExists(atPath: destination)
                                            ? destination : nil)])
        return destination
    }

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
        let existing = path(forID: object.id)
        try writeFiles([StagedWriteInput(destination: destination,
                                         data: Data(VaultDocument.render(object).utf8),
                                         previous: existing)])
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

    /// Returns the objects that explicitly cite a source or memory. Text similarity is useful for
    /// discovery, but it is not provenance; backlinks must come from a declared evidence id.
    public func backlinks(to id: String) -> [MemoryObject] {
        let candidates = Set([id, "memory:\(id)", "note:\(id)", "conversation:\(id)"])
        return objects()
            .filter { !$0.evidence.isEmpty && $0.evidence.contains { candidates.contains($0) } }
            .sorted { $0.createdAt > $1.createdAt }
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
        try writeFiles([StagedWriteInput(destination: path,
                                         data: try encoder.encode(commit), previous: path)])
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

        var files: [StagedWriteInput] = []
        for conflictID in commit.conflicts {
            guard var previous = load(id: conflictID) else { continue }
            previous.status = .superseded
            previous.supersededBy = object.id
            previous.validUntil = date
            let destination = (objectsFolder as NSString).appendingPathComponent(filename(for: previous))
            files.append(StagedWriteInput(destination: destination,
                                          data: Data(VaultDocument.render(previous).utf8),
                                          previous: self.path(forID: previous.id)))
        }
        let objectPath = (objectsFolder as NSString).appendingPathComponent(filename(for: object))
        files.append(StagedWriteInput(destination: objectPath,
                                      data: Data(VaultDocument.render(object).utf8),
                                      previous: path(forID: object.id)))

        var decided = commit
        decided.state = .confirmed
        decided.decidedAt = date
        let commitPath = (commitsFolder as NSString).appendingPathComponent("\(decided.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        files.append(StagedWriteInput(destination: commitPath,
                                      data: try encoder.encode(decided), previous: commitPath))
        try writeFiles(files)
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

        let existingWords = Set(Phrases.significantWords(existing.statement))
        let incomingWords = Set(Phrases.significantWords(incoming.statement))
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

    // MARK: - Durable multi-file publication

    private struct StagedWriteInput {
        let destination: String
        let payload: StagedPayload
        let previous: String?

        init(destination: String, data: Data, previous: String?) {
            self.destination = destination
            self.payload = .data(data)
            self.previous = previous
        }

        init(destination: String, payload: StagedPayload, previous: String?) {
            self.destination = destination
            self.payload = payload
            self.previous = previous
        }
    }

    private enum StagedPayload {
        case data(Data)
        case file(URL)
    }

    private func stageableAttachmentPath(for url: URL, title: String, at date: Date) throws -> String {
        let originalExtension = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        let stamp = ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "")
        let base = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? url.deletingPathExtension().lastPathComponent
            : title
        let filename = SafeFilename.make("\(stamp)-\(base)-\(UUID().uuidString.prefix(8))",
                                         fallback: "imported-evidence",
                                         extension: originalExtension)
        let importsFolder = (attachmentsFolder as NSString).appendingPathComponent("imports")
        return (importsFolder as NSString).appendingPathComponent(filename)
    }

    /// Publishes a set of related files through a manifest. The filesystem cannot atomically
    /// rename files in different folders as a group; the manifest makes a crash recoverable and
    /// keeps a confirmed memory from becoming visible without its commit history.
    private func writeFiles(_ inputs: [StagedWriteInput]) throws {
        guard !inputs.isEmpty else { return }
        let staging = (root as NSString).appendingPathComponent(
            ".beacon-vault-staging-\(UUID().uuidString)")
        try manager.createDirectory(atPath: staging, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        var durable = false
        do {
            let writes = try inputs.enumerated().map { index, input in
                let staged = (staging as NSString).appendingPathComponent("\(index).blob")
                switch input.payload {
                case .data(let data):
                    try data.write(to: URL(fileURLWithPath: staged), options: .atomic)
                case .file(let url):
                    try manager.copyItem(at: url, to: URL(fileURLWithPath: staged))
                }
                return StagedWrite(staged: staged, destination: input.destination,
                                   previous: input.previous)
            }
            let manifest = try JSONEncoder().encode(StagingManifest(writes: writes))
            try manifest.write(to: URL(fileURLWithPath: (staging as NSString)
                .appendingPathComponent("manifest.json")), options: .atomic)
            durable = true
            try publish(writes)
            try? manager.removeItem(atPath: staging)
        } catch {
            if !durable { try? manager.removeItem(atPath: staging) }
            throw error
        }
    }

    private func publish(_ writes: [StagedWrite]) throws {
        for write in writes {
            if manager.fileExists(atPath: write.staged) {
                if manager.fileExists(atPath: write.destination) {
                    _ = try manager.replaceItemAt(URL(fileURLWithPath: write.destination),
                                                   withItemAt: URL(fileURLWithPath: write.staged))
                } else {
                    let destinationFolder = (write.destination as NSString).deletingLastPathComponent
                    try manager.createDirectory(atPath: destinationFolder,
                                                withIntermediateDirectories: true)
                    try manager.moveItem(atPath: write.staged, toPath: write.destination)
                }
            }
            if let previous = write.previous, previous != write.destination,
               manager.fileExists(atPath: previous) {
                try manager.removeItem(atPath: previous)
            }
        }
    }

    private func recoverStaging() {
        guard let names = try? manager.contentsOfDirectory(atPath: root) else { return }
        for name in names where name.hasPrefix(".beacon-vault-staging-") {
            let staging = (root as NSString).appendingPathComponent(name)
            let manifestPath = (staging as NSString).appendingPathComponent("manifest.json")
            guard let data = manager.contents(atPath: manifestPath),
                  let manifest = try? JSONDecoder().decode(StagingManifest.self, from: data) else {
                try? manager.removeItem(atPath: staging)
                continue
            }
            do {
                try publish(manifest.writes)
                try? manager.removeItem(atPath: staging)
            } catch {
                // A later launch can retry while preserving the manifest as the commit record.
            }
        }
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
