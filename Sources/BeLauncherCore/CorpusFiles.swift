import Foundation

/// The corpus as files, so the brain is auditable, versionable and yours.
///
/// Everything the brain deduces about you — the episodes it assembled, the entities it folded
/// together, the sentences it distilled — is written as plain Markdown with YAML front matter in a
/// folder you choose. Not because the database is not enough: it is. Because asking somebody to
/// let an app watch what they do all day and then keeping the result inside a SQLite file only we
/// can read is not a deal anyone should take. A folder of `.md` files opens in any editor, diffs
/// in git and survives us.
///
/// Open format is not the same as giving up the viewer. Reading, navigating and correcting all
/// happen inside BeLauncher; the folder is what makes the memory portable, not what replaces the
/// product.
///
/// Two rules run through the whole file. Anything a person wrote by hand outranks anything the
/// machine deduced and is never overwritten — see `write(_:over:)`. And a correction survives
/// regeneration even when the body does not, because a correction is the most valuable thing in
/// the corpus: it is the one piece of information the machine could not have produced by itself.
public struct CorpusDocument: Sendable, Equatable, Identifiable {

    public enum Kind: String, Sendable, Equatable, Codable, CaseIterable {
        /// A stretch of work: what you did, as one thing.
        case episode
        /// A person, a project, a company, a subject — with every name it answers to.
        case entity
        /// One distilled sentence, with the episodes it came from.
        case statement

        public var folder: String {
            switch self {
            case .episode: "episodes"
            case .entity: "entities"
            case .statement: "statements"
            }
        }

        public var label: String {
            switch self {
            case .episode: "Episodio"
            case .entity: "Entidad"
            case .statement: "Frase"
            }
        }
    }

    /// What a person told the brain it got wrong, or right.
    ///
    /// Kept apart from the rest of the document on purpose: the body can be rewritten by the next
    /// distillation pass, a correction never can. This is the only part of the corpus that cannot
    /// be recomputed from the raw signals, so losing it is the one loss that cannot be undone.
    public struct Corrections: Sendable, Equatable {
        /// Said out loud that this matters. Ends every relevance argument — see `Relevance.score`.
        public var pinned: Bool
        /// Told to stay out of the graph. Kept as a fact rather than as a deletion so re-capturing
        /// the same thing tomorrow does not resurrect it.
        public var hidden: Bool
        /// This entity turned out to be another one.
        public var mergedInto: String?
        /// Merges already refused, by `MergeProposal.id`. Remembered forever: asking twice about
        /// the same pair turns correcting the brain into arguing with it.
        public var rejectedMerges: Set<String>
        /// What the mark applies to, in the words the assembly compares against.
        ///
        /// A mark is on a piece of work, not on a filename, and it is kept here rather than in the
        /// body because an episode's id is derived from the signals it holds: the afternoon gains
        /// one more file and the id changes. A mark filed under the old id quietly stops applying
        /// to the same work. These strings are what `CorpusBuilder.weigh` reads out of
        /// `Episode.subjects`, and they survive the file being rebuilt.
        public var markedSubjects: Set<String>
        /// Somebody rewrote the body. From here on the machine keeps its hands off this file.
        public var editedByHand: Bool
        public var editedAt: Date?

        public init(pinned: Bool = false, hidden: Bool = false, mergedInto: String? = nil,
                    rejectedMerges: Set<String> = [], markedSubjects: Set<String> = [],
                    editedByHand: Bool = false, editedAt: Date? = nil) {
            self.pinned = pinned
            self.hidden = hidden
            self.mergedInto = mergedInto
            self.rejectedMerges = rejectedMerges
            self.markedSubjects = markedSubjects
            self.editedByHand = editedByHand
            self.editedAt = editedAt
        }

        public var isEmpty: Bool {
            !pinned && !hidden && mergedInto == nil && rejectedMerges.isEmpty
                && markedSubjects.isEmpty && !editedByHand
        }
    }

    public let kind: Kind
    public let id: String
    public var title: String
    /// When what this describes happened. Ordering in the reader, and the time axis in the graph.
    public var occurredAt: Date
    /// Markdown, heading included. Verbatim: what a person types here is what stays here.
    public var body: String
    /// Extra scalar front matter, whatever the kind needs.
    public var fields: [String: String]
    /// Extra list front matter. `links` lives here, and so do an entity's aliases.
    public var lists: [String: [String]]
    public var corrections: Corrections

    public init(kind: Kind, id: String, title: String, occurredAt: Date, body: String,
                fields: [String: String] = [:], lists: [String: [String]] = [:],
                corrections: Corrections = Corrections()) {
        self.kind = kind
        self.id = id
        self.title = title
        self.occurredAt = occurredAt
        self.body = body
        self.fields = fields
        self.lists = lists
        self.corrections = corrections
    }

    /// Everything this document points at, by canonical name.
    public var links: [String] { lists["links"] ?? [] }
}

public enum CorpusFiles {

    /// The folders the corpus lives in, with what each one holds.
    ///
    /// New folders rather than the vault's `objects` and `commits`, and that is not a preference.
    /// Every `.md` inside those two is parsed back as a memory, which is why `VaultGuide` refuses
    /// to drop an explanatory note in them. The same trap applies here — everything in these three
    /// is read back as corpus — so the explanation goes in the README at the root and `parse`
    /// refuses anything without our front matter instead of guessing.
    public static let folders: [(name: String, purpose: String)] = [
        ("episodes", L("What you did, in stretches: one file per episode of work.")),
        ("entities", L("Who and what: people, projects, companies and subjects, with every name they answer to.")),
        ("statements", L("What the brain concluded from your days, every sentence with its citation.")),
    ]

    /// Folders whose every `.md` is read back as memory. Nothing else goes in them.
    public static let machineRead: Set<String> = Set(folders.map(\.name))

    public static let readme = """
    # Lo que el cerebro sabe de ti

    Esta carpeta es el corpus: episodios, entidades y frases, en Markdown normal con front matter
    YAML y enlaces `[[así]]`. Se puede abrir en cualquier editor, versionar con git y llevártela
    entera el día que dejes BeLauncher.

    Que el formato sea abierto no significa que necesites otra app para mirarlo. Verlo, navegarlo y
    corregirlo se hace en BeLauncher, en el grafo y en el lector. La carpeta existe para que la
    memoria sea auditable y tuya, no para mandarte a otro sitio.

    | Carpeta | Qué hay dentro |
    |---|---|
    | `episodes` | Un archivo por tramo de trabajo: qué tocaste, cuándo y durante cuánto. |
    | `entities` | Una persona, un proyecto, una empresa o un asunto, con todos sus alias. |
    | `statements` | Frases destiladas de tus días. Cada una cita el episodio del que salió. |

    ## Lo que edites a mano manda

    Si cambias el texto de un archivo, se marca `edited_by_hand: true` y la máquina no vuelve a
    tocarlo nunca. Lo que dedujo el cerebro es una propuesta; lo que escribiste tú es la verdad.

    Lo mismo con las correcciones que haces desde el grafo: marcar algo como importante, ocultarlo
    o decir que dos entidades no son la misma queda en el front matter y sobrevive a que la máquina
    reescriba el archivo. Son lo único que el cerebro no puede deducir solo.

    ## Estas tres carpetas se leen enteras

    Cada `.md` de aquí dentro se interpreta como corpus. Si quieres dejarte notas sueltas, ponlas
    fuera: un archivo sin nuestro front matter se ignora, pero es mejor no jugársela.
    """

    // MARK: - Building documents from what the brain deduced

    /// An episode as a file: what you did, in the order you did it.
    public static func document(for episode: Episode, links: [String] = [],
                                now: Date = .now) -> CorpusDocument {
        let title = episode.title.isEmpty ? episode.fallbackTitle : episode.title
        let minutes = max(1, Int(episode.duration / 60))
        let clock = clockFormatter()

        var body = "# \(title)\n\n"
        body += "\(minutes) min · \(dayFormatter().string(from: episode.start))"
        body += " · " + L("from %1$@ to %2$@", clock.string(from: episode.start),
                          clock.string(from: episode.end)) + "\n"
        body += L("\n## What you touched\n\n")
        for signal in episode.signals.sorted(by: { $0.at < $1.at }) {
            body += "- \(clock.string(from: signal.at)) · \(label(signal.kind)) · \(signal.title)\n"
        }
        if !links.isEmpty {
            body += L("\n## What it has to do with\n\n")
            body += links.map(wikilink).joined(separator: " · ") + "\n"
        }

        return CorpusDocument(
            kind: .episode, id: episode.id, title: title, occurredAt: episode.start, body: body,
            fields: ["minutes": String(minutes), "until": VaultDocument.iso(episode.end)],
            lists: ["links": links, "subjects": episode.subjects]
        )
    }

    /// An entity as a file, with every name it answers to.
    ///
    /// The aliases are written out rather than kept in the index alone because they are the part a
    /// person is most likely to want to fix: seeing "waw-trips" and "WAW Trips" listed under one
    /// name is what makes an unnoticed bad merge noticeable.
    public static func document(for entity: Entity, seenAt: Date = .now,
                                links: [String] = []) -> CorpusDocument {
        var body = "# \(entity.canonical)\n\n"
        body += entity.kind.label + " · " + L("seen %@ time(s)", String(entity.weight)) + "\n"
        if !entity.aliases.isEmpty {
            body += L("\n## Also called\n\n")
            body += entity.aliases.sorted().map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if !links.isEmpty {
            body += L("\n## Turns up with\n\n")
            body += links.map(wikilink).joined(separator: " · ") + "\n"
        }

        return CorpusDocument(
            kind: .entity, id: entity.id, title: entity.canonical, occurredAt: seenAt, body: body,
            fields: ["entity_kind": entity.kind.rawValue, "weight": String(entity.weight)],
            lists: ["aliases": entity.aliases.sorted(), "links": links]
        )
    }

    /// Reads an entity back out of its file, so a correction made in an editor reaches the engine.
    public static func entity(from document: CorpusDocument) -> Entity? {
        guard document.kind == .entity,
              let kind = Entity.Kind(rawValue: document.fields["entity_kind"] ?? "") else { return nil }
        return Entity(id: document.id, kind: kind, canonical: document.title,
                      aliases: Set(document.lists["aliases"] ?? []),
                      weight: Int(document.fields["weight"] ?? "1") ?? 1)
    }

    /// One distilled sentence, with its citations.
    ///
    /// The sources are written into the file, not just referenced by the index. A sentence whose
    /// citation cannot be followed is exactly the kind of confident nonsense the distillation pass
    /// exists to refuse, and a file is where somebody would go to check.
    public static func document(for statement: Distillation.Statement,
                                titles: [String: String] = [:]) -> CorpusDocument {
        var body = "# \(statement.text)\n\n"
        body += "\(dayFormatter().string(from: statement.day))\n"
        body += L("\n## Where it comes from\n\n")
        for source in statement.sources {
            body += "- \(wikilink(titles[source] ?? source))\n"
        }
        return CorpusDocument(
            kind: .statement, id: statement.id, title: statement.text,
            occurredAt: statement.day, body: body,
            lists: ["sources": statement.sources,
                    "links": statement.sources.map { titles[$0] ?? $0 }]
        )
    }

    // MARK: - Corrections

    /// What a person can tell the brain it got wrong.
    public enum Correction: Sendable, Equatable {
        /// «Esto importa». The subjects travel with it so the mark reaches the assembly; without
        /// them the front matter said `pinned: true` and the ranking never heard about it.
        case markImportant(Bool, subjects: [String] = [])
        case hide(Bool)
        case rename(String)
        /// «No, no son lo mismo». Remembered forever.
        case rejectMerge(MergeProposal)
        /// This entity was folded into another one.
        case mergedInto(String)
    }

    public static func apply(_ correction: Correction, to document: CorpusDocument,
                             at date: Date = .now) -> CorpusDocument {
        var result = document
        switch correction {
        case .markImportant(let value, let subjects):
            result.corrections.pinned = value
            // Added to rather than replaced: the same piece of work can be marked from the graph
            // and from the reader, and the second one arriving with a shorter list of subjects
            // must not narrow what the first one said. Unmarking clears the lot, because that is
            // the person taking it back.
            result.corrections.markedSubjects = value
                ? result.corrections.markedSubjects.union(subjects)
                : []
        case .hide(let value): result.corrections.hidden = value
        case .rename(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return document }
            result.title = trimmed
        case .rejectMerge(let proposal): result.corrections.rejectedMerges.insert(proposal.id)
        case .mergedInto(let other): result.corrections.mergedInto = other
        }
        // Deliberately not marked as a hand edit. Saying "this matters" is not rewriting the text,
        // and treating it as one would freeze the file: the episode would never pick up the rest
        // of its own signals just because somebody starred it halfway through.
        result.corrections.editedAt = date
        return result
    }

    /// Somebody rewrote the text. From here on this file is theirs.
    public static func handEdit(_ document: CorpusDocument, body: String,
                                at date: Date = .now) -> CorpusDocument {
        var result = document
        result.body = body
        result.corrections.editedByHand = true
        result.corrections.editedAt = date
        // The heading a person writes is the title they meant. Reading it back out keeps the front
        // matter, the reader's list and the graph label saying the same thing as the file.
        if let heading = body.split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("# ") })?
            .dropFirst(2).trimmingCharacters(in: .whitespaces), !heading.isEmpty {
            result.title = heading
        }
        return result
    }

    /// Every merge already refused, ready to hand to `Identity.decide(rejected:)`.
    public static func rejected(in documents: [CorpusDocument]) -> Set<String> {
        documents.reduce(into: Set<String>()) { $0.formUnion($1.corrections.rejectedMerges) }
    }

    // MARK: - Handing the corrections back to the engine

    /// What the person corrected, in the shape the assembly takes it in.
    ///
    /// This is the return leg, and it was missing. Rejecting a merge in the graph wrote
    /// `rejected_merges` into the front matter while the assembly read its rejections from a
    /// setting nothing ever wrote — measured on a folder with the rejection on disk, the same pair
    /// was proposed again on the next pass. Marking something important had the same shape: the
    /// file said `pinned: true` and `Relevance.Signals.markedByHand` never heard about it.
    ///
    /// The corrections stay in the front matter and nowhere else. A mirror of them in the database
    /// would be a second truth, and the two disagreeing about whether two entities are the same
    /// thing is precisely what this folder exists to settle.
    public struct Learned: Sendable, Equatable {
        /// Merge questions already answered no, by `MergeProposal.id`.
        public var rejectedMerges: Set<String>
        /// Subjects, not document ids: what `CorpusBuilder.weigh` compares against.
        public var markedByHand: Set<String>
        /// Documents told to stay out of the graph, by id.
        public var hidden: Set<String>

        public init(rejectedMerges: Set<String> = [], markedByHand: Set<String> = [],
                    hidden: Set<String> = []) {
            self.rejectedMerges = rejectedMerges
            self.markedByHand = markedByHand
            self.hidden = hidden
        }

        public var isEmpty: Bool {
            rejectedMerges.isEmpty && markedByHand.isEmpty && hidden.isEmpty
        }
    }

    public static func learned(in documents: [CorpusDocument]) -> Learned {
        var result = Learned()
        for document in documents {
            result.rejectedMerges.formUnion(document.corrections.rejectedMerges)
            if document.corrections.hidden { result.hidden.insert(document.id) }
            guard document.corrections.pinned else { continue }
            result.markedByHand.formUnion(document.corrections.markedSubjects)
            // Files written before the mark carried its own subjects still work: an episode
            // document has always listed what it was about, and dropping those would make an old
            // mark quietly stop counting the day this shipped.
            result.markedByHand.formUnion(document.lists["subjects"] ?? [])
        }
        return result
    }

    /// The same, read straight off disk without opening the folder object.
    ///
    /// `CorpusFolder` is bound to the main actor because it writes; this only reads, and the pass
    /// that needs it runs off the main actor on purpose. Parsing a few hundred small files on the
    /// main actor to find out what somebody rejected would put the cost back where the hot key is.
    public static func learned(inFolderAt root: String) -> Learned {
        let manager = FileManager.default
        var documents: [CorpusDocument] = []
        for kind in CorpusDocument.Kind.allCases {
            let folder = (root as NSString).appendingPathComponent(kind.folder)
            guard let names = try? manager.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where name.hasSuffix(".md") {
                let path = (folder as NSString).appendingPathComponent(name)
                guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                      let document = parse(text) else { continue }
                documents.append(document)
            }
        }
        return learned(in: documents)
    }

    public static func hidden(in documents: [CorpusDocument]) -> Set<String> {
        Set(documents.filter(\.corrections.hidden).map(\.id))
    }

    public static func pinned(in documents: [CorpusDocument]) -> Set<String> {
        Set(documents.filter(\.corrections.pinned).map(\.id))
    }

    // MARK: - Deciding what to write

    public enum Write: Sendable, Equatable {
        /// Put this on disk.
        case write(String)
        /// Somebody wrote this file. Machine keeps out.
        case keepHandEdit
        /// Byte for byte what is already there.
        case unchanged
    }

    /// What to do with a freshly deduced document when a file already exists.
    ///
    /// Two rules, and the order matters. A hand-edited file is never touched, full stop — the
    /// alternative is a person watching their own words get replaced by the machine's guess, which
    /// ends the trust the whole corpus depends on. Otherwise the new content wins but the
    /// corrections carry over, because those are the one thing regeneration cannot reproduce.
    public static func write(_ fresh: CorpusDocument, over existing: String?) -> Write {
        guard let existing, let previous = parse(existing) else { return .write(render(fresh)) }
        guard !previous.corrections.editedByHand else { return .keepHandEdit }

        var merged = fresh
        merged.corrections = previous.corrections
        // A renamed entity keeps its name. Renaming is a correction too; letting the next pass
        // overwrite it would make the rename look like it never happened.
        if previous.title != fresh.title, previous.corrections.editedAt != nil {
            merged.title = previous.title
        }
        let rendered = render(merged)
        return rendered == existing ? .unchanged : .write(rendered)
    }

    // MARK: - Markdown

    /// Front matter keys the document owns. Anything else in `fields` or `lists` is written after.
    static let reservedKeys: Set<String> = [
        "kind", "id", "title", "at", "pinned", "hidden", "merged_into", "rejected_merges",
        "marked_subjects", "edited_by_hand", "edited_at",
    ]

    public static func render(_ document: CorpusDocument) -> String {
        var lines = ["---"]
        lines.append("kind: \(document.kind.rawValue)")
        lines.append("id: \(VaultDocument.quote(document.id))")
        lines.append("title: \(VaultDocument.quote(document.title))")
        lines.append("at: \(VaultDocument.iso(document.occurredAt))")

        for key in document.fields.keys.sorted() where !reservedKeys.contains(key) {
            lines.append("\(key): \(VaultDocument.quote(document.fields[key] ?? ""))")
        }
        for key in document.lists.keys.sorted() where !reservedKeys.contains(key) {
            let values = document.lists[key] ?? []
            guard !values.isEmpty else { continue }
            lines.append("\(key): [\(values.map(VaultDocument.quote).joined(separator: ", "))]")
        }

        let corrections = document.corrections
        if corrections.pinned { lines.append("pinned: true") }
        if corrections.hidden { lines.append("hidden: true") }
        if let mergedInto = corrections.mergedInto {
            lines.append("merged_into: \(VaultDocument.quote(mergedInto))")
        }
        if !corrections.rejectedMerges.isEmpty {
            let sorted = corrections.rejectedMerges.sorted().map(VaultDocument.quote)
            lines.append("rejected_merges: [\(sorted.joined(separator: ", "))]")
        }
        if !corrections.markedSubjects.isEmpty {
            let sorted = corrections.markedSubjects.sorted().map(VaultDocument.quote)
            lines.append("marked_subjects: [\(sorted.joined(separator: ", "))]")
        }
        if corrections.editedByHand { lines.append("edited_by_hand: true") }
        if let editedAt = corrections.editedAt {
            lines.append("edited_at: \(VaultDocument.iso(editedAt))")
        }
        lines.append("---")
        lines.append("")
        return lines.joined(separator: "\n") + "\n" + document.body
    }

    /// Reads a corpus file back, or refuses.
    ///
    /// Refuses on purpose when the front matter is not ours. These folders are read whole, so a
    /// stray note somebody dropped in would otherwise become a memory the brain believes.
    public static func parse(_ text: String) -> CorpusDocument? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let closing = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return nil }

        var scalars: [String: String] = [:]
        var lists: [String: [String]] = [:]
        for line in lines[1..<closing] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("["), raw.hasSuffix("]") {
                lists[key] = VaultDocument.list(raw)
            } else {
                scalars[key] = VaultDocument.unquote(raw)
            }
        }

        guard let kind = CorpusDocument.Kind(rawValue: scalars["kind"] ?? ""),
              let id = scalars["id"], !id.isEmpty else { return nil }

        // The body is kept verbatim, heading and all. Anything clever here — dropping the title
        // line, trimming inner blank lines — would silently rewrite what a person typed the next
        // time the file was saved.
        let body = lines[(closing + 1)...]
            .drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")

        let corrections = CorpusDocument.Corrections(
            pinned: scalars["pinned"] == "true",
            hidden: scalars["hidden"] == "true",
            mergedInto: scalars["merged_into"],
            rejectedMerges: Set(lists["rejected_merges"] ?? []),
            markedSubjects: Set(lists["marked_subjects"] ?? []),
            editedByHand: scalars["edited_by_hand"] == "true",
            editedAt: VaultDocument.date(scalars["edited_at"])
        )

        var fields = scalars
        for key in reservedKeys { fields.removeValue(forKey: key) }
        var extraLists = lists
        for key in reservedKeys { extraLists.removeValue(forKey: key) }

        return CorpusDocument(
            kind: kind, id: id, title: scalars["title"] ?? id,
            occurredAt: VaultDocument.date(scalars["at"]) ?? .distantPast,
            body: body, fields: fields, lists: extraLists, corrections: corrections
        )
    }

    /// `[[Así]]`, the link everybody's editor already understands.
    public static func wikilink(_ name: String) -> String {
        // Brackets inside a name would close the link early and leave half a title as prose.
        let cleaned = name
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "[[\(cleaned)]]"
    }

    /// Every `[[link]]` in a piece of Markdown, in order, without repeats.
    public static func links(in markdown: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        var rest = Substring(markdown)
        while let open = rest.range(of: "[["), let close = rest.range(of: "]]", range: open.upperBound..<rest.endIndex) {
            let name = String(rest[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, seen.insert(name).inserted { found.append(name) }
            rest = rest[close.upperBound...]
        }
        return found
    }

    // MARK: - Filenames

    /// A stable, short handle for an id, used as the filename suffix.
    ///
    /// The file can then be found by its id without opening a single one: a folder with three
    /// thousand episodes would otherwise be read end to end on every save.
    public static func handle(for id: String) -> String {
        String(Semantic.digest(id).prefix(8))
    }

    public static func filename(for document: CorpusDocument) -> String {
        let stamp = ISO8601DateFormatter.vaultStamp().string(from: document.occurredAt)
        let slug = Importers.slug(String(document.title.prefix(50)))
        let base = slug.isEmpty ? document.kind.rawValue : slug
        return SafeFilename.make("\(stamp)-\(base)-\(handle(for: document.id))", extension: "md")
    }

    public static func relativePath(for document: CorpusDocument) -> String {
        document.kind.folder + "/" + filename(for: document)
    }

    static func label(_ kind: Episode.Signal.Kind) -> String {
        switch kind {
        case .file: L("File")
        case .application: "App"
        case .meeting: L("Meeting")
        case .conversation: L("Conversation")
        case .clip: L("Clipboard")
        case .note: L("Note")
        }
    }

    /// Fresh formatters each time: `DateFormatter` is not `Sendable`, and one shared instance
    /// would be a data race the first time indexing moved off the main actor.
    static func clockFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateFormat = "d 'de' MMMM 'de' yyyy"
        return formatter
    }
}

// MARK: - The folder on disk

/// The corpus folder: reads, writes and never overwrites what a person wrote.
///
/// Deliberately not a cache of the database. The database is derived data that can be dropped and
/// rebuilt; this folder holds the corrections, which cannot. If the two ever disagree about
/// whether two entities are the same thing, the folder is right.
@MainActor
public final class CorpusFolder {
    public let root: String
    private let manager: FileManager

    public init(root: String, manager: FileManager = .default) throws {
        self.root = root
        self.manager = manager
        for folder in CorpusFiles.folders {
            try manager.createDirectory(atPath: (root as NSString).appendingPathComponent(folder.name),
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
        // A filename on disk, not interface copy: it keeps the name it was created with.
        let readme = (root as NSString).appendingPathComponent("LÉEME — corpus.md")
        if !manager.fileExists(atPath: readme) {
            try? CorpusFiles.readme.write(toFile: readme, atomically: true, encoding: .utf8)
        }
    }

    public static func defaultRoot() -> String { Vault.defaultRoot() }

    public func folder(_ kind: CorpusDocument.Kind) -> String {
        (root as NSString).appendingPathComponent(kind.folder)
    }

    /// Where a document lives right now, found by its id rather than by its title.
    ///
    /// Titles change — a hand edit is exactly somebody changing one — and a filename derived from
    /// the title would leave two files claiming the same id, with "what is true" depending on the
    /// order the directory happened to be listed in.
    public func existingPath(for id: String, kind: CorpusDocument.Kind) -> String? {
        let suffix = "-" + CorpusFiles.handle(for: id) + ".md"
        guard let names = try? manager.contentsOfDirectory(atPath: folder(kind)) else { return nil }
        guard let name = names.first(where: { $0.hasSuffix(suffix) }) else { return nil }
        return (folder(kind) as NSString).appendingPathComponent(name)
    }

    /// Writes a deduced document, respecting whatever the person did to it.
    @discardableResult
    public func save(_ document: CorpusDocument) throws -> CorpusFiles.Write {
        let current = existingPath(for: document.id, kind: document.kind)
        let existing = current.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let decision = CorpusFiles.write(document, over: existing)
        guard case .write(let contents) = decision else { return decision }

        let destination = (folder(document.kind) as NSString)
            .appendingPathComponent(CorpusFiles.filename(for: document))
        if let current, current != destination { try? manager.removeItem(atPath: current) }
        try contents.write(toFile: destination, atomically: true, encoding: .utf8)
        return decision
    }

    /// Writes what a person typed. The one path that is allowed to replace a hand-edited file,
    /// because the person is the one doing it.
    @discardableResult
    public func saveHandEdit(_ document: CorpusDocument, body: String,
                             at date: Date = .now) throws -> CorpusDocument {
        let edited = CorpusFiles.handEdit(document, body: body, at: date)
        try force(edited)
        return edited
    }

    /// Applies a correction and writes it, hand edit or not: a correction is the person speaking.
    @discardableResult
    public func apply(_ correction: CorpusFiles.Correction, to document: CorpusDocument,
                      at date: Date = .now) throws -> CorpusDocument {
        let corrected = CorpusFiles.apply(correction, to: document, at: date)
        try force(corrected)
        return corrected
    }

    private func force(_ document: CorpusDocument) throws {
        let current = existingPath(for: document.id, kind: document.kind)
        let destination = (folder(document.kind) as NSString)
            .appendingPathComponent(CorpusFiles.filename(for: document))
        if let current, current != destination { try? manager.removeItem(atPath: current) }
        try CorpusFiles.render(document).write(toFile: destination, atomically: true, encoding: .utf8)
    }

    public func load(id: String, kind: CorpusDocument.Kind) -> CorpusDocument? {
        guard let path = existingPath(for: id, kind: kind),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return CorpusFiles.parse(text)
    }

    public func documents(kind: CorpusDocument.Kind? = nil) -> [CorpusDocument] {
        let kinds = kind.map { [$0] } ?? CorpusDocument.Kind.allCases
        var result: [CorpusDocument] = []
        for kind in kinds {
            guard let names = try? manager.contentsOfDirectory(atPath: folder(kind)) else { continue }
            for name in names where name.hasSuffix(".md") {
                let path = (folder(kind) as NSString).appendingPathComponent(name)
                guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                      let document = CorpusFiles.parse(text) else { continue }
                result.append(document)
            }
        }
        return result.sorted { $0.occurredAt > $1.occurredAt }
    }

    public func delete(_ document: CorpusDocument) {
        guard let path = existingPath(for: document.id, kind: document.kind) else { return }
        try? manager.removeItem(atPath: path)
    }
}
