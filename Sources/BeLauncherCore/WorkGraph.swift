import Foundation

/// Operational memory: who you work with, on what, through which files and meetings.
///
/// The vault already held what the company *believes* — decisions, policies, commitments. That is
/// semantic memory. This is the other half: what you were *doing*. People, companies, projects,
/// files, meetings and the edges between them, built from what actually happens on this Mac rather
/// than from anything anyone remembered to type in.
///
/// It is a real graph and not a bag of tags on purpose. "¿Qué prometimos a Andrés?" cannot be
/// answered by matching the string "Andrés" against statements: it needs the commitments whose
/// subject is the person node Andrés, including the ones that name him nowhere because they came
/// out of a meeting he was in. Tags cannot express "came out of"; edges can.
public struct WorkNode: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case person
        case company
        case project
        case file
        case meeting
        case conversation
        case decision
        case commitment
        case application

        public var label: String {
            switch self {
            case .person: L("Person")
            case .company: L("Company")
            case .project: L("Project")
            case .file: L("File")
            case .meeting: L("Meeting")
            case .conversation: L("Conversation")
            case .decision: L("Decision")
            case .commitment: "Compromiso"
            case .application: "App"
            }
        }

        public var symbol: String {
            switch self {
            case .person: "person"
            case .company: "building.2"
            case .project: "folder.badge.gearshape"
            case .file: "doc"
            case .meeting: "calendar"
            case .conversation: "bubble.left.and.bubble.right"
            case .decision: "checkmark.seal"
            case .commitment: "hand.raised"
            case .application: "app.dashed"
            }
        }
    }

    public let id: String
    public let kind: Kind
    public var name: String
    /// A line a person would read: the file's folder, the meeting's time, the project's status.
    public var detail: String
    /// Something to open: a path, a URL, a memory id. Empty when the node is only a concept.
    public var target: String
    public var lastSeen: Date
    /// How often this has come up. Ranking, not truth.
    public var weight: Int

    public init(id: String, kind: Kind, name: String, detail: String = "", target: String = "",
                lastSeen: Date = .now, weight: Int = 1) {
        self.id = id
        self.kind = kind
        self.name = name
        self.detail = detail
        self.target = target
        self.lastSeen = lastSeen
        self.weight = weight
    }

    /// Stable across runs so the same person seen twice is one node, not two.
    public static func identifier(kind: Kind, name: String) -> String {
        let folded = name
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(kind.rawValue):\(folded)"
    }
}

public struct WorkEdge: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// A person attended a meeting; a file belongs to a project.
        case partOf
        /// A commitment or decision came out of a meeting or conversation.
        case cameFrom
        /// A person owes, or is owed, something.
        case owes
        /// Two things were worked on together in the same stretch of time.
        case workedWith
        /// A person belongs to a company.
        case worksAt

        public var label: String {
            switch self {
            case .partOf: L("is part of")
            case .cameFrom: L("came out of")
            case .owes: "debe"
            case .workedWith: L("worked on together")
            case .worksAt: L("works on")
            }
        }
    }

    public let source: String
    public let target: String
    public let kind: Kind
    public let at: Date

    public init(source: String, target: String, kind: Kind, at: Date = .now) {
        self.source = source
        self.target = target
        self.kind = kind
        self.at = at
    }
}

// MARK: - Storage

extension Store {

    public func upsertNode(_ node: WorkNode) {
        try? database.execute("""
            INSERT INTO work_nodes (id, kind, name, detail, target, lastSeen, weight)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                detail = CASE WHEN excluded.detail = '' THEN work_nodes.detail ELSE excluded.detail END,
                target = CASE WHEN excluded.target = '' THEN work_nodes.target ELSE excluded.target END,
                lastSeen = MAX(work_nodes.lastSeen, excluded.lastSeen),
                weight = work_nodes.weight + 1
            """,
            [.text(node.id), .text(node.kind.rawValue), .text(node.name), .text(node.detail),
             .text(node.target), .double(node.lastSeen.timeIntervalSince1970),
             .int(Int64(node.weight))]
        )
    }

    public func link(_ edge: WorkEdge) {
        try? database.execute("""
            INSERT INTO work_edges (source, target, kind, at) VALUES (?, ?, ?, ?)
            ON CONFLICT(source, target, kind) DO UPDATE SET at = excluded.at
            """,
            [.text(edge.source), .text(edge.target), .text(edge.kind.rawValue),
             .double(edge.at.timeIntervalSince1970)]
        )
    }

    public func nodes(kind: WorkNode.Kind? = nil, limit: Int = 500) -> [WorkNode] {
        let sql = kind == nil
            ? "SELECT * FROM work_nodes ORDER BY lastSeen DESC LIMIT ?"
            : "SELECT * FROM work_nodes WHERE kind = ? ORDER BY lastSeen DESC LIMIT ?"
        let arguments: [SQLValue] = kind == nil
            ? [.int(Int64(limit))]
            : [.text(kind!.rawValue), .int(Int64(limit))]
        let rows = (try? database.query(sql, arguments)) ?? []
        return rows.map(Self.node(from:))
    }

    public func node(id: String) -> WorkNode? {
        let rows = (try? database.query("SELECT * FROM work_nodes WHERE id = ?", [.text(id)])) ?? []
        return rows.first.map(Self.node(from:))
    }

    public func edges(from id: String) -> [WorkEdge] {
        let rows = (try? database.query(
            "SELECT * FROM work_edges WHERE source = ? OR target = ?", [.text(id), .text(id)]
        )) ?? []
        return rows.compactMap { row in
            guard let kind = WorkEdge.Kind(rawValue: row.string("kind")) else { return nil }
            return WorkEdge(source: row.string("source"), target: row.string("target"),
                            kind: kind, at: Date(timeIntervalSince1970: row.double("at")))
        }
    }

    public func workEdges(limit: Int = 5_000) -> [WorkEdge] {
        let rows = (try? database.query(
            "SELECT * FROM work_edges ORDER BY at DESC LIMIT ?", [.int(Int64(limit))]
        )) ?? []
        return rows.compactMap { row in
            guard let kind = WorkEdge.Kind(rawValue: row.string("kind")) else { return nil }
            return WorkEdge(source: row.string("source"), target: row.string("target"),
                            kind: kind, at: Date(timeIntervalSince1970: row.double("at")))
        }
    }

    public func clearWorkGraph() {
        try? database.execute("DELETE FROM work_nodes")
        try? database.execute("DELETE FROM work_edges")
    }

    static func node(from row: Row) -> WorkNode {
        WorkNode(
            id: row.string("id"),
            kind: WorkNode.Kind(rawValue: row.string("kind")) ?? .project,
            name: row.string("name"), detail: row.string("detail"), target: row.string("target"),
            lastSeen: Date(timeIntervalSince1970: row.double("lastSeen")),
            weight: Int(row.int("weight"))
        )
    }
}

// MARK: - Questions

/// The questions the graph exists to answer, in the words someone would actually type.
public enum WorkQuery {

    public struct Answer: Sendable, Equatable {
        public let headline: String
        public let nodes: [WorkNode]
        public let body: String

        public init(headline: String, nodes: [WorkNode], body: String) {
            self.headline = headline
            self.nodes = nodes
            self.body = body
        }
    }

    public enum Intent: Sendable, Equatable {
        /// "¿Qué prometimos a Andrés?"
        case promisedTo(String)
        /// "Abre lo último relacionado con Project Atlas"
        case lastAbout(String)
        /// "Retoma lo que estaba haciendo antes de la llamada"
        case resumeBefore
        /// "¿Quién es Acme?" — everything connected to one node.
        case about(String)

        public static func detect(_ query: String) -> Intent? {
            let folded = Phrases.fold(query)

            if let name = Phrases.after(anyOf: Phrases.promisedTo, in: folded) {
                return .promisedTo(name)
            }
            if let subject = Phrases.after(anyOf: Phrases.lastAbout, in: folded) {
                return .lastAbout(subject)
            }
            if Phrases.matches(anyOf: Phrases.resumeBefore, in: folded) { return .resumeBefore }
            if let subject = Phrases.after(anyOf: Phrases.about, in: folded) {
                return .about(subject)
            }
            return nil
        }
    }

    /// Commitments owed to a person: the ones naming them and the ones that merely came out of
    /// something they were in. The second kind is the whole reason this is a graph.
    public static func promised(
        to name: String, nodes: [WorkNode], edges: [WorkEdge], memories: [MemoryObject],
        at date: Date = .now
    ) -> Answer {
        let personID = WorkNode.identifier(kind: .person, name: name)
        let direct = memories.filter { object in
            object.kind == .commitment && object.status == .active
                && (object.statement.localizedCaseInsensitiveContains(name)
                    || object.entities.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame })
        }

        // Anything that came out of a meeting this person was part of.
        let theirMeetings = Set(edges
            .filter { $0.kind == .partOf && $0.source == personID }
            .map(\.target))
        let indirectIDs = Set(edges
            .filter { $0.kind == .cameFrom && theirMeetings.contains($0.target) }
            .map(\.source))
        let indirect = nodes.filter { indirectIDs.contains($0.id) && $0.kind == .commitment }

        var lines: [String] = direct.map { object in
            let due = object.validUntil.map { " · " + L("due %@", shortDate($0)) } ?? ""
            let late = (object.validUntil.map { $0 < date } ?? false) ? " ⚠︎ " + L("overdue") : ""
            return "- \(object.statement)\(due)\(late)"
        }
        lines += indirect.map { "- \($0.name) · \($0.detail)" }

        return Answer(
            headline: lines.isEmpty
                ? L("Nothing outstanding with %@", name)
                : L("%1$@ commitment(s) with %2$@", String(lines.count), name),
            nodes: indirect,
            body: lines.isEmpty
                ? L("No open commitments, and nothing that came out of a meeting of theirs.")
                : lines.joined(separator: "\n")
        )
    }

    /// The most recent things touching a subject, newest first, ready to open.
    public static func last(about subject: String, nodes: [WorkNode], edges: [WorkEdge],
                            limit: Int = 8) -> Answer {
        let folded = subject
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let anchors = nodes.filter {
            $0.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .contains(folded)
        }
        let anchorIDs = Set(anchors.map(\.id))
        let neighbourIDs = Set(edges
            .filter { anchorIDs.contains($0.source) || anchorIDs.contains($0.target) }
            .flatMap { [$0.source, $0.target] })
            .subtracting(anchorIDs)

        let related = nodes
            .filter { neighbourIDs.contains($0.id) && !$0.target.isEmpty }
            .sorted { $0.lastSeen > $1.lastSeen }
            .prefix(limit)

        return Answer(
            headline: related.isEmpty
                ? L("Nothing recent about %@", subject)
                : L("The latest on %@", subject),
            nodes: Array(related),
            body: related.map { "- \($0.name) · \($0.detail)" }.joined(separator: "\n")
        )
    }

    /// What you had open before the most recent meeting started.
    ///
    /// "Antes de la llamada" is a real anchor and not a vague one: a calendar event has a start
    /// time, so the files and apps touched in the half hour before it are exactly the context that
    /// got interrupted.
    public static func resume(nodes: [WorkNode], meetings: [CalendarEvent], at date: Date = .now,
                              window: TimeInterval = 1_800) -> Answer {
        let recentMeeting = meetings
            .filter { $0.start <= date }
            .max(by: { $0.start < $1.start })

        guard let meeting = recentMeeting else {
            return Answer(headline: L("There is no recent meeting to go back to"), nodes: [],
                          body: L("With nothing in the calendar, there is no “before” to talk about."))
        }
        let from = meeting.start.addingTimeInterval(-window)
        let before = nodes
            .filter { $0.lastSeen >= from && $0.lastSeen <= meeting.start && !$0.target.isEmpty }
            .sorted { $0.lastSeen > $1.lastSeen }
            .prefix(6)

        return Answer(
            headline: before.isEmpty
                ? L("Nothing was left half done before “%@”", meeting.title)
                : L("Before “%@” you were on this", meeting.title),
            nodes: Array(before),
            body: before.map { "- \($0.name) · \($0.detail)" }.joined(separator: "\n")
        )
    }

    /// Everything hanging off one node.
    public static func about(_ name: String, nodes: [WorkNode], edges: [WorkEdge]) -> Answer {
        let folded = name
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard let anchor = nodes.first(where: {
            $0.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                == folded
        }) ?? nodes.first(where: {
            $0.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .contains(folded)
        }) else {
            return Answer(headline: L("I do not know “%@”", name), nodes: [],
                          body: L("It has not turned up in anything you have done here yet."))
        }
        let connected = edges.filter { $0.source == anchor.id || $0.target == anchor.id }
        let others = connected.compactMap { edge -> (WorkNode, WorkEdge.Kind)? in
            let otherID = edge.source == anchor.id ? edge.target : edge.source
            guard let node = nodes.first(where: { $0.id == otherID }) else { return nil }
            return (node, edge.kind)
        }
        return Answer(
            headline: "\(anchor.name) · \(anchor.kind.label)",
            nodes: others.map(\.0),
            body: others.isEmpty
                ? L("No connections yet.")
                : others.map { "- \($0.0.name) (\($0.1.label))" }.joined(separator: "\n")
        )
    }

    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        // The interface language decides, not the machine's region: this string sits inside an
        // English sentence, and a US-format date next to Spanish text (or the reverse) is the kind
        // of seam that makes a product feel translated.
        formatter.locale = Loc.language.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
