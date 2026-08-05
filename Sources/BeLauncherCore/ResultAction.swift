import Foundation

/// One verb that can be applied to a result.
///
/// The model Raycast established and people now expect: ↩ runs the primary action, ⌘↩ runs the
/// second one, ⌘K opens the full panel, and every action shows the shortcut that triggers it.
public struct ResultAction: Sendable, Equatable, Identifiable {
    public enum Section: String, Sendable, CaseIterable {
        case primary = ""
        case copy = "Copiar"
        case manage = "Gestionar"
        case danger = "Peligro"
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
        case deleteSnippet(id: Int64)
        case deleteWorkflow(id: Int64)
        case deleteFlow(id: Int64)
        case completeKeyword(String)
        case openSettings
        case moveToTrash(path: String)
        case systemCommand(String)
        case assignAlias(target: String, suggestion: String)
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
        switch result.kind {
        case .application:
            return [
                ResultAction(id: "open", title: "Abrir", symbol: "arrow.up.forward.app",
                             shortcut: .enter, intent: .run),
                ResultAction(id: "reveal", title: "Mostrar en Finder", symbol: "folder",
                             shortcut: .commandEnter, intent: .reveal(path: result.payload)),
                ResultAction(id: "copy-path", title: "Copiar ruta", symbol: "doc.on.doc",
                             shortcut: .copyPath, section: .copy, intent: .copy(text: result.payload)),
                ResultAction(id: "alias", title: "Asignar un alias", symbol: "textformat.abc",
                             section: .manage,
                             intent: .assignAlias(target: result.payload, suggestion: result.title)),
            ]

        case .file:
            return [
                ResultAction(id: "open", title: "Abrir", symbol: "arrow.up.forward.app",
                             shortcut: .enter, intent: .run),
                ResultAction(id: "reveal", title: "Mostrar en Finder", symbol: "folder",
                             shortcut: .commandEnter, intent: .reveal(path: result.payload)),
                ResultAction(id: "quicklook", title: "Vista rápida", symbol: "eye",
                             shortcut: .quickLook, intent: .quickLook(path: result.payload)),
                ResultAction(id: "open-with", title: "Abrir con…", symbol: "square.and.arrow.up",
                             shortcut: .openWith, intent: .openWith(path: result.payload)),
                ResultAction(id: "copy-path", title: "Copiar ruta", symbol: "doc.on.doc",
                             shortcut: .copyPath, section: .copy, intent: .copy(text: result.payload)),
                ResultAction(id: "trash", title: "Mover a la papelera", symbol: "trash",
                             shortcut: .delete, section: .danger, isDestructive: true,
                             intent: .moveToTrash(path: result.payload)),
            ]

        case .clipboard:
            return [
                ResultAction(id: "paste", title: "Pegar", symbol: "doc.on.clipboard",
                             shortcut: .enter, intent: .run),
                ResultAction(id: "copy", title: "Copiar", symbol: "doc.on.doc",
                             shortcut: .copy, section: .copy, intent: .copy(text: result.payload)),
                ResultAction(id: "remember", title: "Recordar esto", symbol: "brain",
                             shortcut: .remember,
                             section: .manage,
                             intent: .remember(text: result.payload, source: result.subtitle)),
                ResultAction(id: "pin", title: "Fijar arriba", symbol: "pin",
                             section: .manage, intent: .setPinned(true, clip: result.recordID)),
                ResultAction(id: "as-snippet", title: "Guardar como snippet", symbol: "text.quote",
                             shortcut: .save, section: .manage,
                             intent: .saveClipAsSnippet(text: result.payload)),
                ResultAction(id: "delete", title: "Borrar del historial", symbol: "trash",
                             shortcut: .delete, section: .danger, isDestructive: true,
                             intent: .deleteClip(id: result.recordID)),
            ]

        case .snippet:
            return [
                ResultAction(id: "copy-expanded", title: "Copiar expandido", symbol: "doc.on.clipboard",
                             shortcut: .enter, intent: .run),
                ResultAction(id: "settings", title: "Editar en Ajustes", symbol: "gearshape",
                             section: .manage, intent: .openSettings),
                ResultAction(id: "delete", title: "Borrar snippet", symbol: "trash",
                             shortcut: .delete, section: .danger, isDestructive: true,
                             intent: .deleteSnippet(id: result.recordID)),
            ]

        case .workflow:
            var actions = [
                ResultAction(id: "run", title: result.payload.isEmpty ? "Completar palabra clave" : "Abrir",
                             symbol: "bolt.horizontal", shortcut: .enter, intent: .run),
            ]
            if let completion = result.completion {
                actions.append(ResultAction(id: "complete", title: "Completar palabra clave",
                                            symbol: "arrow.right.to.line", shortcut: .tab,
                                            intent: .completeKeyword(completion)))
            }
            if !result.payload.isEmpty {
                actions.append(ResultAction(id: "copy-url", title: "Copiar enlace", symbol: "link",
                                            shortcut: .copy, section: .copy,
                                            intent: .copy(text: result.payload)))
            }
            actions.append(ResultAction(id: "delete", title: "Borrar workflow", symbol: "trash",
                                        shortcut: .delete, section: .danger, isDestructive: true,
                                        intent: .deleteWorkflow(id: result.recordID)))
            return actions

        case .flow:
            return [
                ResultAction(id: "run", title: "Ejecutar flujo", symbol: "play.fill",
                             shortcut: .enter, intent: .run),
                ResultAction(id: "settings", title: "Editar pasos", symbol: "gearshape",
                             section: .manage, intent: .openSettings),
                ResultAction(id: "delete", title: "Borrar flujo", symbol: "trash",
                             shortcut: .delete, section: .danger, isDestructive: true,
                             intent: .deleteFlow(id: result.recordID)),
            ]

        case .bookmark:
            return [
                ResultAction(id: "open", title: "Abrir enlace", symbol: "safari",
                             shortcut: .enter, intent: .run),
                ResultAction(id: "copy-url", title: "Copiar enlace", symbol: "link",
                             shortcut: .copy, section: .copy, intent: .copy(text: result.payload)),
            ]

        case .memory:
            return [
                ResultAction(id: "copy", title: "Copiar la frase", symbol: "doc.on.clipboard",
                             shortcut: .enter, intent: .run),
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
                ResultAction(id: "copy-name", title: "Copiar nombre", symbol: "doc.on.doc",
                             shortcut: .copy, section: .copy, intent: .copy(text: result.payload)),
            ]

        case .window:
            return [
                ResultAction(id: "arrange", title: "Colocar la ventana", symbol: "macwindow",
                             shortcut: .enter, intent: .run),
            ]

        case .system:
            return [
                ResultAction(id: "run", title: "Ejecutar", symbol: "play.fill",
                             shortcut: .enter, intent: .run),
            ]

        case .calculation:
            return [
                ResultAction(id: "copy", title: "Copiar resultado", symbol: "doc.on.clipboard",
                             shortcut: .enter, intent: .run),
                ResultAction(id: "paste", title: "Pegar en la app anterior", symbol: "arrow.down.doc",
                             shortcut: .commandEnter, intent: .paste(text: result.payload)),
            ]
        }
    }

    /// The action bound to ⌘↩: the second one in the list, following the platform convention.
    public static func secondary(for result: SearchResult) -> ResultAction? {
        let all = actions(for: result)
        return all.count > 1 ? all[1] : nil
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
