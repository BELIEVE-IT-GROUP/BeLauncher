import Foundation

/// Fills the graph from what already happens, instead of asking you to type it.
///
/// The previous version of the brain only knew what someone had dictated into it, which meant it
/// knew almost nothing: nobody stops mid-task to record that they opened a file. Everything here
/// comes from sources that are already on the Mac — the calendar, the files you touched, the apps
/// you launched — so there is no account to connect, nothing to authorise beyond what the app
/// already asks for, and no server involved.
///
/// The deliberate limit: it records *that* something happened and what it was called. It never
/// reads the contents of a file, a message or a page. A graph of titles is enough to answer "what
/// was I doing before the call"; a graph of contents would be a different product with a different
/// promise.
public enum Capture {

    /// One thing that happened, ready to become nodes and edges.
    public struct Event: Sendable, Equatable {
        public let node: WorkNode
        public let links: [WorkEdge]

        public init(node: WorkNode, links: [WorkEdge] = []) {
            self.node = node
            self.links = links
        }
    }

    // MARK: - From the calendar

    /// A meeting, the people in it, and the companies those people belong to.
    ///
    /// This is where most of the graph's value comes from: attendees are the only reliable source
    /// of "who you actually work with", and a meeting is the anchor that lets a commitment be tied
    /// to a person who is never named in its text.
    public static func events(from meetings: [CalendarEvent]) -> [Event] {
        var captured: [Event] = []
        for meeting in meetings {
            let meetingID = WorkNode.identifier(kind: .meeting, name: meeting.title)
            captured.append(Event(node: WorkNode(
                id: meetingID, kind: .meeting, name: meeting.title,
                detail: describe(meeting), lastSeen: meeting.start
            )))

            for attendee in meeting.attendees {
                let person = person(named: attendee, at: meeting.start)
                var links = [WorkEdge(source: person.node.id, target: meetingID, kind: .partOf,
                                      at: meeting.start)]
                links += person.links
                captured.append(Event(node: person.node, links: links))
            }
        }
        return captured
    }

    /// A person, plus their company when the name carries one.
    ///
    /// An email address is the cheapest reliable signal of who someone works for, and it is already
    /// in the calendar entry. Free mail domains are excluded because "gmail" is not a company.
    public static func person(named raw: String, at date: Date = .now) -> Event {
        let name = displayName(from: raw)
        let node = WorkNode(id: WorkNode.identifier(kind: .person, name: name), kind: .person,
                            name: name, detail: raw.contains("@") ? raw : "", lastSeen: date)
        guard let company = company(fromEmail: raw) else { return Event(node: node) }

        let companyID = WorkNode.identifier(kind: .company, name: company)
        return Event(node: node, links: [
            WorkEdge(source: node.id, target: companyID, kind: .worksAt, at: date),
        ])
    }

    /// Contacts become people in the operational graph. Only the display name and the first
    /// useful contact detail are retained; the Contacts database remains the source of truth.
    public static func contacts(_ contacts: [ContactItem], at date: Date = .now) -> [Event] {
        contacts.map { contact in
            let detail = [contact.email, contact.phone].filter { !$0.isEmpty }
                .joined(separator: " · ")
            return Event(node: WorkNode(
                id: "person:contact:\(contact.id)",
                kind: .person, name: contact.name, detail: detail,
                target: "bel://contacts/\(contact.id)", lastSeen: date
            ))
        }
    }

    /// Pending Reminders become operational commitments. They are not committed Brain memories:
    /// the source remains Reminders, and the next refresh can update the same node or remove it.
    public static func reminders(_ reminders: [ReminderItem], at date: Date = .now) -> [Event] {
        reminders.map { reminder in
            Event(node: WorkNode(
                id: WorkNode.identifier(kind: .commitment, name: "reminder:\(reminder.id)"),
                kind: .commitment,
                name: reminder.title,
                detail: [reminder.list, reminder.displayDueDate]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                target: "bel://reminders/\(reminder.id)",
                lastSeen: reminder.dueDate ?? date
            ))
        }
    }

    /// A photo enters the graph only when the person explicitly keeps it. The original stays in
    /// Photos; the Brain receives metadata and a stable local reference, never the image bytes.
    public static func photo(_ photo: PhotoItem, at date: Date = .now) -> Event {
        let dimensions = photo.width > 0 && photo.height > 0
            ? "\(photo.width) × \(photo.height)" : ""
        let detail = [photo.album, photo.mediaType, dimensions,
                      photo.isFavorite ? L("Favorite") : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        return Event(node: WorkNode(
            id: "photo:\(photo.id)", kind: .file, name: photo.title,
            detail: detail, target: "bel://photos/\(photo.id)", lastSeen: photo.creationDate ?? date
        ))
    }

    static let freeMailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com",
        "hotmail.com", "live.com", "yahoo.com", "proton.me", "protonmail.com", "aol.com",
    ]

    public static func company(fromEmail raw: String) -> String? {
        guard let at = raw.lastIndex(of: "@") else { return nil }
        let domain = String(raw[raw.index(after: at)...]).lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty, !freeMailDomains.contains(domain) else { return nil }
        // "acme.co.uk" → "Acme". The first label is the company in every case worth handling.
        guard let first = domain.split(separator: ".").first, first.count > 1 else { return nil }
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    public static func displayName(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@"), let local = trimmed.split(separator: "@").first else {
            return trimmed
        }
        // "jorge.beltran@acme.com" → "Jorge Beltran". Better than showing a raw address in a list.
        return local
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func describe(_ meeting: CalendarEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var text = formatter.string(from: meeting.start)
        if !meeting.attendees.isEmpty {
            text += L(" · %@ person(s)", String(meeting.attendees.count))
        }
        return text
    }

    // MARK: - From files and apps

    /// A file you opened, tied to the project its folder implies.
    ///
    /// The folder is the project. It is a heuristic and it is right often enough to be useful:
    /// people already organise work into folders, so `~/Clients/Acme/propuesta.pdf` says both what
    /// the file is and what it belongs to without anyone tagging anything.
    public static func file(at path: String, at date: Date = .now) -> Event {
        let name = (path as NSString).lastPathComponent
        let node = WorkNode(
            id: WorkNode.identifier(kind: .file, name: path), kind: .file, name: name,
            detail: (path as NSString).deletingLastPathComponent, target: path, lastSeen: date
        )
        guard let project = project(forPath: path) else { return Event(node: node) }

        let projectID = WorkNode.identifier(kind: .project, name: project)
        return Event(node: node, links: [
            WorkEdge(source: node.id, target: projectID, kind: .partOf, at: date),
        ])
    }

    /// Folders that describe where something lives, not what it is about.
    static let genericFolders: Set<String> = [
        "desktop", "documents", "downloads", "escritorio", "documentos", "descargas",
        "library", "applications", "movies", "music", "pictures", "public", "icloud drive",
        "mobile documents", "users", "tmp", "var",
    ]

    public static func project(forPath path: String) -> String? {
        let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard !folder.isEmpty, folder != "/" else { return nil }
        guard !genericFolders.contains(folder.lowercased()) else { return nil }
        guard folder != NSString(string: NSHomeDirectory()).lastPathComponent else { return nil }
        return folder
    }

    public static func application(named name: String, path: String, at date: Date = .now) -> Event {
        Event(node: WorkNode(
            id: WorkNode.identifier(kind: .application, name: name), kind: .application,
            name: name, detail: "App", target: path, lastSeen: date
        ))
    }

    /// A mail message is a referenceable work item, not a second mailbox. Its target remains the
    /// original `.emlx` file so the reader can open the source when the person needs full context.
    public static func mail(_ message: MailMessage) -> Event {
        let title = message.subject.isEmpty ? L("Email") : message.subject
        let detail = [message.sender, message.recipients].filter { !$0.isEmpty }
            .joined(separator: " · ")
        return Event(node: WorkNode(
            id: WorkNode.identifier(kind: .conversation, name: message.messageID),
            kind: .conversation, name: title, detail: detail,
            target: message.sourcePath, lastSeen: message.at
        ))
    }

    public static func message(_ message: MessageRecord) -> Event {
        Event(node: WorkNode(
            id: WorkNode.identifier(kind: .conversation, name: message.messageID),
            kind: .conversation, name: String(message.text.prefix(90)),
            detail: message.sender, target: message.sourcePath, lastSeen: message.at
        ))
    }

    public static func note(_ note: NoteRecord) -> Event {
        Event(node: WorkNode(
            id: WorkNode.identifier(kind: .file, name: note.noteID),
            kind: .file, name: String(note.text.prefix(90)),
            detail: L("Apple Note"), target: note.sourcePath, lastSeen: note.at
        ))
    }

    // MARK: - From the vault

    /// Decisions and commitments become nodes so the graph can connect them to the meeting they
    /// came out of, which is what makes "¿qué prometimos a Andrés?" answerable at all.
    public static func memory(_ object: MemoryObject, fromMeeting meeting: String? = nil) -> Event {
        let kind: WorkNode.Kind = object.kind == .commitment ? .commitment : .decision
        let node = WorkNode(
            id: "\(kind.rawValue):\(object.id)", kind: kind, name: object.statement,
            detail: object.owner.isEmpty ? object.source : object.owner,
            target: object.id, lastSeen: object.validFrom
        )
        guard let meeting else { return Event(node: node) }
        return Event(node: node, links: [
            WorkEdge(source: node.id,
                     target: WorkNode.identifier(kind: .meeting, name: meeting),
                     kind: .cameFrom, at: object.validFrom),
        ])
    }

    /// Things worked on within the same short stretch are related, and that relation is what
    /// "retoma lo que estaba haciendo" walks. Half an hour: long enough to cover a real task,
    /// short enough that two unrelated sessions do not merge into one.
    public static let sessionWindow: TimeInterval = 1_800

    public static func sessions(_ nodes: [WorkNode],
                                window: TimeInterval = sessionWindow) -> [WorkEdge] {
        let ordered = nodes.sorted { $0.lastSeen < $1.lastSeen }
        var edges: [WorkEdge] = []
        for (index, node) in ordered.enumerated() {
            for other in ordered[(index + 1)...] {
                guard other.lastSeen.timeIntervalSince(node.lastSeen) <= window else { break }
                guard node.id != other.id else { continue }
                edges.append(WorkEdge(source: node.id, target: other.id, kind: .workedWith,
                                      at: other.lastSeen))
            }
        }
        return edges
    }
}
