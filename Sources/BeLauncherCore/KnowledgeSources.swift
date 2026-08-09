import Foundation

/// The source contract shown to the person and used by the Brain to describe its coverage.
///
/// This is intentionally a catalog before it becomes a connector framework: a planned source must
/// be visible as planned, never appear connected just because its name is in a settings screen.
public struct KnowledgeSource: Identifiable, Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case connected
        case available
        case manual
        case planned
        case unsupported
    }

    public let id: String
    public let title: String
    public let scope: String
    public let state: State
    public let symbol: String

    public init(id: String, title: String, scope: String, state: State, symbol: String) {
        self.id = id
        self.title = title
        self.scope = scope
        self.state = state
        self.symbol = symbol
    }
}

public enum KnowledgeSourceCatalog {
    /// Current coverage plus explicit gaps. Keeping the gaps here prevents aspirational copy from
    /// becoming a false capability claim when a new connector is mentioned in the UI.
    public static var current: [KnowledgeSource] {
        [
            .init(id: "clipboard", title: L("Clipboard"),
                  scope: L("Copied text, images and files, when capture is enabled."),
                  state: .available, symbol: "doc.on.clipboard"),
            .init(id: "browsers", title: L("Safari and Chrome"),
                  scope: L("Page titles and URLs from browser history."),
                  state: .available, symbol: "safari"),
            .init(id: "conversations", title: L("AI conversations"),
                  scope: L("Local assistant sessions in the configured sessions folder."),
                  state: .available, symbol: "bubble.left.and.bubble.right"),
            .init(id: "calendar", title: L("Calendar"),
                  scope: L("Meeting titles, times and attendees after permission."),
                  state: .available, symbol: "calendar"),
            .init(id: "reminders", title: L("Reminders"),
                  scope: L("Pending reminders and due dates after permission."),
                  state: .available, symbol: "checklist"),
            .init(id: "contacts", title: L("Contacts"),
                  scope: L("Names and contact details after permission."),
                  state: .available, symbol: "person.crop.circle"),
            .init(id: "photos", title: L("Photos"),
                  scope: L("Local photo metadata after permission."),
                  state: .available, symbol: "photo"),
            .init(id: "audio", title: L("Audio and calls"),
                  scope: L("Explicit recordings and selected audio folders; never background listening."),
                  state: .manual, symbol: "waveform"),
            .init(id: "files", title: L("Files"),
                  scope: L("Search by filename through Spotlight; content is not automatically indexed yet."),
                  state: .available, symbol: "doc.text"),
            .init(id: "apps", title: L("Applications"),
                  scope: L("Installed apps for search, plus frontmost-app activity metadata when capture is enabled."),
                  state: .available, symbol: "square.grid.2x2"),
            .init(id: "notes", title: L("Apple Notes"),
                  scope: L("Plain snippets from the local Notes store; encrypted payloads are excluded."),
                  state: .available, symbol: "note.text"),
            .init(id: "messages", title: L("Apple Messages"),
                  scope: L("Recent text messages from the local Messages database; attachments are excluded."),
                  state: .available, symbol: "message"),
            .init(id: "whatsapp", title: L("WhatsApp"),
                  scope: L("WhatsApp is detected when present, but this build only reads it after a supported local message store is verified."),
                  state: .planned, symbol: "message"),
            .init(id: "apple-mail", title: L("Apple Mail"),
                  scope: L("Recent relevant messages with a reference to the original local .emlx file."),
                  state: .available, symbol: "envelope"),
            .init(id: "mail-and-chats", title: L("Gmail, Outlook and work chats"),
                  scope: L("Planned connectors for Gmail, Outlook, Slack, Teams and Discord."),
                  state: .planned, symbol: "envelope"),
        ]
    }
}
