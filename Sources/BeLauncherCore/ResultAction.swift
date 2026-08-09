import Foundation

/// One verb that can be applied to a result.
///
/// The model Raycast established and people now expect: ↩ runs the primary action, ⌘↩ runs the
/// second one, ⌘K opens the full panel, and every action shows the shortcut that triggers it.
public struct ResultAction: Sendable, Equatable, Identifiable {
    public enum Section: String, Sendable, CaseIterable {
        case primary = ""
        case copy = "copy"
        case ai = "ai"
        case manage = "manage"
        case danger = "danger"

        /// The heading the person reads above the group.
        ///
        /// Separate from the raw value on purpose. The raw value used to be the Spanish heading
        /// itself, which made the identifier and the label the same string: translating the label
        /// would have silently renamed the identifier that Settings parses out of a stored
        /// preference. An identifier is not copy.
        public var label: String {
            switch self {
            case .primary: ""
            case .copy: L("Copy")
            case .ai: L("With AI")
            case .manage: L("Manage")
            case .danger: L("Danger")
            }
        }
    }

    public let id: String
    public let title: String
    public let symbol: String
    /// Displayed on the right of the row, e.g. "⌘↩". Nil means it only runs from the panel.
    public let shortcut: Shortcut?
    public let section: Section
    /// Destructive actions are tinted and always ask before running.
    public let isDestructive: Bool
    public let intent: Intent

    public init(id: String, title: String, symbol: String, shortcut: Shortcut? = nil,
                section: Section = .primary, isDestructive: Bool = false, intent: Intent) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.section = section
        self.isDestructive = isDestructive
        self.intent = intent
    }

    /// What the app layer must carry out. Kept as data so the whole action system stays testable.
    public enum Intent: Sendable, Equatable {
        case run                       // the result's own default behaviour
        case reveal(path: String)
        case openWith(path: String)
        case quickLook(path: String)
        case copy(text: String)
        case paste(text: String)
        case saveClipAsSnippet(text: String)
        case deleteClip(id: Int64)
        case setPinned(Bool, clip: Int64)
        case remember(text: String, source: String)
        case confirmCommit(String)
        case discardCommit(String)
        case runVerb(id: String, text: String)
        case deleteSnippet(id: Int64)
        case deleteWorkflow(id: Int64)
        case deleteFlow(id: Int64)
        case completeKeyword(String)
        case openSettings
        case moveToTrash(path: String)
        case systemCommand(String)
        case assignAlias(target: String, suggestion: String)
        case writeNote(text: String)
        case openQuickNoteEditor(initialText: String)
        /// Ends a process the hard way. Separate from `run` so it can never be the Enter key.
        case forceQuit(pid: String)
        case openActivityMonitor
    }

    public struct Shortcut: Sendable, Equatable {
        public let display: String
        public let key: Key
        public let command: Bool
        public let shift: Bool
        public let option: Bool

        public enum Key: Sendable, Equatable {
            case character(Character)
            case enter
            case space
            case delete
            case tab
        }

        public init(display: String, key: Key, command: Bool = false, shift: Bool = false, option: Bool = false) {
            self.display = display
            self.key = key
            self.command = command
            self.shift = shift
            self.option = option
        }

        public static let enter = Shortcut(display: "↩", key: .enter)
        public static let commandEnter = Shortcut(display: "⌘↩", key: .enter, command: true)
        public static let copy = Shortcut(display: "⌘C", key: .character("c"), command: true)
        public static let copyPath = Shortcut(display: "⇧⌘C", key: .character("c"), command: true, shift: true)
        public static let openWith = Shortcut(display: "⌘O", key: .character("o"), command: true)
        public static let quickLook = Shortcut(display: "␣", key: .space)
        public static let save = Shortcut(display: "⌘S", key: .character("s"), command: true)
        public static let delete = Shortcut(display: "⌘⌫", key: .delete, command: true)
        public static let tab = Shortcut(display: "⇥", key: .tab)
        public static let remember = Shortcut(display: "⌘R", key: .character("r"), command: true)

        /// True when a real key event corresponds to this shortcut.
        public func matches(characters: String, keyCode: UInt16,
                            command: Bool, shift: Bool, option: Bool) -> Bool {
            guard command == self.command, shift == self.shift, option == self.option else { return false }
            switch key {
            case .character(let c): return characters == String(c)
            case .enter: return keyCode == 36 || keyCode == 76
            case .space: return keyCode == 49
            case .delete: return keyCode == 51 || keyCode == 117
            case .tab: return keyCode == 48
            }
        }
    }
}

/// Decides which verbs apply to which result. Everything added later — AI actions, Be connectors,
/// agent commands — registers here instead of touching the window.
public enum ActionRegistry {

    public static func actions(for result: SearchResult) -> [ResultAction] {
        base(for: result) + aiVerbs(for: result)
    }

    /// The verbs a model can apply to this result, offered only where there is text to work on.
    static func aiVerbs(for result: SearchResult) -> [ResultAction] {
        let text: String
        switch result.kind {
        case .clipboard, .snippet, .answer: text = result.payload
        case .memory: text = result.title
        default: return []
        }
        guard text.count >= 12 else { return [] }

        return AIVerb.suggested(for: text).map { verb in
            ResultAction(id: "ai-\(verb.id)", title: verb.title, symbol: verb.symbol,
                         section: .ai, intent: .runVerb(id: verb.id, text: text))
        }
    }

    private static func base(for result: SearchResult) -> [ResultAction] {
        switch result.kind {
        case .application:
            return [
                ResultAction(id: "open", title: L("Open"), symbol: "arrow.up.forward.app",
                             shortcut: .enter, intent: .run),
                ResultAction(id: "reveal", title: L("Show in Finder"), symbol: "folder",
                             shortcut: .commandEnter, intent: .reveal(path: result.payload)),
                ResultAction(id: "copy-path", title: L("Copy the path"), symbol: "doc.on.doc",
                             shortcut: .copyPath, section: .copy, intent: .copy(text: result.payload)),
                ResultAction(id: "alias", title: L("Give it an alias"), symbol: "textformat.abc",
                             section: .manage,
                             intent: .assignAlias(target: result.payload, suggestion: result.title)),
            ]

        case .file:
            return [
                ResultAction(id: "open", title: L("Open"), symbol: "arrow.up.forward.app",
                             shortcut: .enter, intent: .run),
                ResultAction(id: "reveal", title: L("Show in Finder"), symbol: "folder",
                             shortcut: .commandEnter, intent: .reveal(path: result.payload)),
                ResultAction(id: "quicklook", title: L("Quick look"), symbol: "eye",
                             shortcut: .quickLook, intent: .quickLook(path: result.payload)),
                ResultAction(id: "open-with", title: L("Open with…"), symbol: "square.and.arrow.up",
                             shortcut: .openWith, intent: .openWith(path: result.payload)),
                ResultAction(id: "copy-path", title: L("Copy the path"), symbol: "doc.on.doc",
                             shortcut: .copyPath, section: .copy, intent: .copy(text: result.payload)),
                ResultAction(id: "trash", title: L("Move to the trash"), symbol: "trash",
                             shortcut: .delete, section: .danger, isDestructive: true,
                             intent: .moveToTrash(path: result.payload)),
            ]

        case .clipboard:
            return [
                ResultAction(id: "paste", title: "Pegar", symbol: "doc.on.clipboard",
                             shortcut: .enter, intent: .run),
                ResultAction(id: "copy", title: L("Copy"), symbol: "doc.on.doc",
                             shortcut: .copy, section: .copy, intent: .copy(text: result.payload)),
                ResultAction(id: "remember", title: L("Remember this"), symbol: "brain",
                             shortcut: .remember,
                             section: .manage,
                             intent: .remember(text: result.payload, source: result.subtitle)),
                ResultAction(id: "pin", title: "Fijar arriba", symbol: "pin",
                             section: .manage, intent: .setPinned(true, clip: result.recordID)),
                ResultAction(id: "as-snippet", title: L("Save as a snippet"), symbol: "text.quote",
                             shortcut: .save, section: .manage,
                             intent: .saveClipAsSnippet(text: result.payload)),
                ResultAction(id: "delete", title: L("Delete from the history"), symbol: "trash",
                             shortcut: .delete, section: .danger, isDestructive: true,
                             intent: .deleteClip(id: result.recordID)),
            ]

        case .snippet:
            return [
                ResultAction(id: "copy-expanded", title: L("Copy it expanded"), symbol: "doc.on.clipboard",
                             shortcut: .enter, intent: .run),
                ResultAction(id: "settings", title: L("Edit in Settings"), symbol: "gearshape",
                             section: .manage, intent: .openSettings),
                ResultAction(id: "delete", title: L("Delete the snippet"), symbol: "trash",
                             shortcut: .delete, section: .danger, isDestructive: true,
                             intent: .deleteSnippet(id: result.recordID)),
            ]

        case .workflow:
            var actions = [
                ResultAction(id: "run", title: result.payload.isEmpty ? L("Complete the keyword") : L("Open"),
                             symbol: "bolt.horizontal", shortcut: .enter, intent: .run),
            ]
            if let completion = result.completion {
                actions.append(ResultAction(id: "complete", title: L("Complete the keyword"),
                                            symbol: "arrow.right.to.line", shortcut: .tab,
                                            intent: .completeKeyword(completion)))
            }
            if !result.payload.isEmpty {
                actions.append(ResultAction(id: "copy-url", title: L("Copy the link"), symbol: "link",
                                            shortcut: .copy, section: .copy,
                                            intent: .copy(text: result.payload)))
            }
            actions.append(ResultAction(id: "delete", title: L("Delete the workflow"), symbol: "trash",
                                        shortcut: .delete, section: .danger, isDestructive: true,
                                        intent: .deleteWorkflow(id: result.recordID)))
            return actions

        case .flow:
            return [
                ResultAction(id: "run", title: "Ejecutar flujo", symbol: "play.fill",
                             shortcut: .enter, intent: .run),
                ResultAction(id: "settings", title: L("Edit the steps"), symbol: "gearshape",
                             section: .manage, intent: .openSettings),
                ResultAction(id: "delete", title: L("Delete the flow"), symbol: "trash",
                             shortcut: .delete, section: .danger, isDestructive: true,
                             intent: .deleteFlow(id: result.recordID)),
            ]

        case .bookmark:
            return [
                ResultAction(id: "open", title: L("Open the link"), symbol: "safari",
                             shortcut: .enter, intent: .run),
                ResultAction(id: "copy-url", title: L("Copy the link"), symbol: "link",
                             shortcut: .copy, section: .copy, intent: .copy(text: result.payload)),
            ]

        case .mission:
            return [
                ResultAction(id: "plan", title: L("See the plan"), symbol: "list.bullet.rectangle",
                             shortcut: .enter, intent: .run),
            ]

        case .agent:
            return [
                ResultAction(id: "run-agent", title: "Encargarlo", symbol: "paperplane",
                             shortcut: .enter, intent: .run),
            ]

        case .process:
            // Quitting politely is Enter, because it lets the app save and is right almost
            // always. Forcing is deliberately not on any single key: it loses unsaved work.
            return [
                ResultAction(id: "quit", title: L("Close the app"), symbol: "xmark.circle",
                             shortcut: .enter, intent: .run),
                ResultAction(id: "force-quit", title: L("Force quit (loses what is unsaved)"),
                             symbol: "exclamationmark.octagon", section: .danger,
                             intent: .forceQuit(pid: result.payload)),
                ResultAction(id: "activity", title: L("See it in Activity Monitor"),
                             symbol: "chart.bar", intent: .openActivityMonitor),
            ]

        case .answer:
            if result.id == "reminder-list-create" {
                return [ResultAction(id: "create-list", title: L("Create reminder list"), symbol: "folder.badge.plus",
                                     shortcut: .enter, section: .manage,
                                     intent: .systemCommand("bel:reminders.create_list\u{1F}\(result.payload)"))]
            }
            if result.id == "reminder-create" {
                return [ResultAction(id: "create", title: L("Create reminder"), symbol: "checklist",
                                     shortcut: .enter, section: .manage,
                                     intent: .systemCommand("bel:reminders.create\u{1F}\(result.payload)"))]
            }
            if result.id == "reminder-list" {
                return [ResultAction(id: "show-list", title: L("Show reminders in list"),
                                     symbol: "list.bullet", shortcut: .enter,
                                     intent: .systemCommand("bel:reminders.show_list\u{1F}\(result.payload)"))]
            }
            if result.id == "contact-create" {
                return [ResultAction(id: "create", title: L("Create contact"), symbol: "person.badge.plus",
                                     shortcut: .enter, section: .manage,
                                     intent: .systemCommand("bel:contacts.create\u{1F}\(result.payload)"))]
            }
            if result.id.hasPrefix("source-permission-") {
                return [ResultAction(id: "settings", title: L("Open settings"), symbol: "gearshape",
                                     shortcut: .enter, intent: .openSettings)]
            }
            if result.id.hasPrefix("brain-"), let completion = result.completion {
                return [
                    ResultAction(id: "start", title: L("Start typing this"), symbol: "text.cursor",
                                 shortcut: .enter, intent: .completeKeyword(completion)),
                ]
            }
            if result.id == "note" {
                return [
                    ResultAction(id: "save-note", title: L("Save the note"), symbol: "tray.and.arrow.down",
                                 shortcut: .enter, intent: .writeNote(text: result.payload)),
                    ResultAction(id: "edit-note", title: L("Open the Markdown note editor"),
                                 symbol: "note.text", section: .manage,
                                 intent: .openQuickNoteEditor(initialText: result.payload)),
                ]
            }
            if result.id == "new-note" || result.id == "brain-note" {
                return [
                    ResultAction(id: "open-note-editor", title: L("Open the Markdown note editor"),
                                 symbol: "note.text.badge.plus", shortcut: .enter,
                                 intent: .openQuickNoteEditor(initialText: result.payload)),
                ]
            }
            return [
                ResultAction(id: "copy", title: L("Copy the answer"), symbol: "doc.on.clipboard",
                             shortcut: .enter, intent: .copy(text: result.payload)),
                ResultAction(id: "remember", title: L("Keep as a memory"), symbol: "brain",
                             shortcut: .remember, section: .manage,
                             intent: .remember(text: result.payload, source: result.title)),
            ]

        case .memory:
            return [
                ResultAction(id: "copy", title: L("Copy the sentence"), symbol: "doc.on.clipboard",
                             shortcut: .enter, intent: .run),
            ]

        case .recall:
            return [
                ResultAction(id: "copy", title: L("Copy the passage"), symbol: "doc.on.clipboard",
                             shortcut: .enter, intent: .run),
                ResultAction(id: "remember", title: L("Keep it as a memory"),
                             symbol: "brain", shortcut: .remember, section: .manage,
                             intent: .remember(text: result.payload, source: result.subtitle)),
            ]

        case .pendingCommit:
            return [
                ResultAction(id: "confirm", title: "Confirmar", symbol: "checkmark.seal.fill",
                             shortcut: .enter, intent: .confirmCommit(result.payload)),
                ResultAction(id: "discard", title: "Descartar", symbol: "xmark.bin",
                             shortcut: .delete, section: .danger, isDestructive: true,
                             intent: .discardCommit(result.payload)),
            ]

        case .shortcut:
            return [
                ResultAction(id: "run", title: "Ejecutar atajo", symbol: "play.fill",
                             shortcut: .enter, intent: .run),
                ResultAction(id: "copy-name", title: L("Copy the name"), symbol: "doc.on.doc",
                             shortcut: .copy, section: .copy, intent: .copy(text: result.payload)),
            ]

        case .reminder:
            if result.id.hasPrefix("completed-reminder-") {
                return [
                    ResultAction(id: "copy", title: L("Copy the reminder"), symbol: "doc.on.clipboard",
                                 shortcut: .enter, intent: .copy(text: result.title)),
                    ResultAction(id: "uncomplete", title: L("Undo completion"), symbol: "arrow.uturn.backward.circle",
                                 section: .manage,
                                 intent: .systemCommand("bel:reminders.uncomplete\u{1F}\(result.payload)")),
                ]
            }
            return [
                ResultAction(id: "copy", title: L("Copy the reminder"), symbol: "doc.on.clipboard",
                             shortcut: .enter, intent: .copy(text: result.title)),
                ResultAction(id: "open", title: L("Open reminder"), symbol: "checklist",
                             section: .manage,
                             intent: .systemCommand("bel:reminders.open\u{1F}\(result.payload)")),
                ResultAction(id: "complete", title: L("Complete reminder"), symbol: "checkmark.circle",
                             section: .manage, isDestructive: true,
                             intent: .systemCommand("bel:reminders.complete\u{1F}\(result.payload)")),
                ResultAction(id: "due-date", title: L("Change due date"), symbol: "calendar.badge.clock",
                             section: .manage,
                             intent: .systemCommand("bel:reminders.change_due_date\u{1F}\(result.payload)")),
                ResultAction(id: "notes", title: L("Add notes"), symbol: "note.text.badge.plus",
                             section: .manage,
                             intent: .systemCommand("bel:reminders.add_notes\u{1F}\(result.payload)")),
                ResultAction(id: "list", title: L("Move to list"), symbol: "list.bullet.rectangle",
                             section: .manage,
                             intent: .systemCommand("bel:reminders.change_list\u{1F}\(result.payload)")),
                ResultAction(id: "priority", title: L("Set priority"), symbol: "exclamationmark.3",
                             section: .manage,
                             intent: .systemCommand("bel:reminders.set_priority\u{1F}\(result.payload)")),
                ResultAction(id: "delete", title: L("Delete reminder"), symbol: "trash",
                             section: .danger, isDestructive: true,
                             intent: .systemCommand("bel:reminders.delete\u{1F}\(result.payload)")),
            ]

        case .contact:
            return [ResultAction(id: "copy", title: L("Copy contact"), symbol: "doc.on.clipboard",
                                 shortcut: .enter, intent: .copy(text: result.subtitle)),
                    ResultAction(id: "details", title: L("Show contact details"), symbol: "person.text.rectangle",
                                 section: .manage,
                                 intent: .systemCommand("bel:contacts.get_details\u{1F}\(result.payload)")),
                    ResultAction(id: "copy-detail", title: L("Copy email or phone"), symbol: "doc.on.doc",
                                 section: .copy,
                                 intent: .systemCommand("bel:contacts.copy_email\u{1F}\(result.payload)")),
                    ResultAction(id: "open", title: L("Open contact"), symbol: "person.crop.circle",
                                 section: .manage,
                                 intent: .systemCommand("bel:contacts.open\u{1F}\(result.payload)")),
                    ResultAction(id: "share", title: L("Share contact"), symbol: "square.and.arrow.up",
                                 section: .manage,
                                 intent: .systemCommand("bel:contacts.share\u{1F}\(result.payload)")),
                    ResultAction(id: "edit", title: L("Edit contact"), symbol: "pencil",
                                 section: .manage,
                                 intent: .systemCommand("bel:contacts.update\u{1F}\(result.payload)"))]

        case .photo:
            let assetID = photoAssetID(for: result)
            return [ResultAction(id: "open", title: L("Open photo"), symbol: "photo",
                                 shortcut: .enter,
                                 intent: .systemCommand("bel:photos.open\u{1F}\(assetID)")),
                    ResultAction(id: "copy", title: L("Copy Photos ID"), symbol: "doc.on.doc",
                                 shortcut: .copy, section: .copy, intent: .copy(text: assetID)),
                    ResultAction(id: "album", title: L("Add to album"), symbol: "rectangle.stack.badge.plus",
                                 section: .manage,
                                 intent: .systemCommand("bel:photos.add_to_album\u{1F}\(assetID)")),
                    ResultAction(id: "create-album", title: L("Create album with photo"), symbol: "rectangle.stack.badge.plus",
                                 section: .manage,
                                 intent: .systemCommand("bel:photos.create_album\u{1F}\(assetID)")),
                    ResultAction(id: "ocr", title: L("Extract text from photo"), symbol: "text.viewfinder",
                                 section: .manage,
                                 intent: .systemCommand("bel:photos.extract_text\u{1F}\(assetID)")),
                    ResultAction(id: "remember", title: L("Keep in Brain"), symbol: "brain.head.profile",
                                 section: .manage,
                                 intent: .systemCommand("bel:photos.remember\u{1F}\(assetID)"))]

        case .window:
            return [
                ResultAction(id: "arrange", title: L("Place the window"), symbol: "macwindow",
                             shortcut: .enter, intent: .run),
            ]

        case .system:
            return [
                ResultAction(id: "run", title: "Ejecutar", symbol: "play.fill",
                             shortcut: .enter, intent: .run),
            ]

        case .calculation:
            return [
                ResultAction(id: "copy", title: L("Copy the result"), symbol: "doc.on.clipboard",
                             shortcut: .enter, intent: .run),
                ResultAction(id: "paste", title: L("Paste into the previous app"), symbol: "arrow.down.doc",
                             shortcut: .commandEnter, intent: .paste(text: result.payload)),
            ]
        }
    }

    /// The action bound to ⌘↩: the second one in the list, following the platform convention.
    public static func secondary(for result: SearchResult) -> ResultAction? {
        let all = actions(for: result)
        return all.count > 1 ? all[1] : nil
    }

    private static func photoAssetID(for result: SearchResult) -> String {
        let prefix = "photo-"
        guard result.id.hasPrefix(prefix) else { return result.payload }
        return String(result.id.dropFirst(prefix.count))
    }

    /// Filters the panel as the user types inside it.
    public static func filter(_ actions: [ResultAction], query: String) -> [ResultAction] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return actions }
        return actions
            .compactMap { action -> (ResultAction, Int)? in
                guard let match = Fuzzy.match(query: trimmed, candidate: action.title) else { return nil }
                return (action, match.score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}
