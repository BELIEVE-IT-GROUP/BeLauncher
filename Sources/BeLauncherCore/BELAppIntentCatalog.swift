import Foundation

public enum BELAppIntentExecutionMode: String, Codable, Sendable, Equatable {
    case background
    case foreground
}

public enum BELAppIntentRuntimeStatus: String, Codable, Sendable, Equatable {
    case implemented
    case reviewOnly
}

public struct BELAppIntentDefinition: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let command: String
    public let executionMode: BELAppIntentExecutionMode
    public let runtimeStatus: BELAppIntentRuntimeStatus

    public init(id: String, title: String, command: String,
                executionMode: BELAppIntentExecutionMode,
                runtimeStatus: BELAppIntentRuntimeStatus) {
        self.id = id
        self.title = title
        self.command = command
        self.executionMode = executionMode
        self.runtimeStatus = runtimeStatus
    }
}

/// The discoverable App Intent surface is deliberately smaller than the action inventory.
/// `reviewOnly` means BeLauncher opens the exact command for user review; it is never reported
/// as a completed background action.
public enum BELAppIntentCatalog {
    public static let curated: [BELAppIntentDefinition] = [
        .init(id: "clipboard.summarize", title: "Summarize Clipboard", command: "summarise clipboard", executionMode: .foreground, runtimeStatus: .implemented),
        .init(id: "clipboard.rewrite", title: "Rewrite Clipboard", command: "shorter clipboard", executionMode: .foreground, runtimeStatus: .implemented),
        .init(id: "clipboard.translate", title: "Translate Clipboard", command: "translate clipboard", executionMode: .foreground, runtimeStatus: .implemented),
        .init(id: "clipboard.ask", title: "Ask About Clipboard", command: "ask about clipboard", executionMode: .foreground, runtimeStatus: .implemented),
        .init(id: "file.summarize", title: "Summarize Selected File", command: "summarise selected file", executionMode: .foreground, runtimeStatus: .reviewOnly),
        .init(id: "file.ask", title: "Ask About Selected File", command: "ask about selected file", executionMode: .foreground, runtimeStatus: .reviewOnly),
        .init(id: "file.rename", title: "Smart Rename Selected File", command: "rename selected file", executionMode: .foreground, runtimeStatus: .reviewOnly),
        .init(id: "email.draft", title: "Draft Email", command: "draft email", executionMode: .foreground, runtimeStatus: .reviewOnly),
        .init(id: "email.reply", title: "Reply in My Voice", command: "reply in my voice", executionMode: .foreground, runtimeStatus: .reviewOnly),
        .init(id: "clipboard.tasks", title: "Create Tasks from Clipboard", command: "extract tasks from clipboard", executionMode: .foreground, runtimeStatus: .implemented),
        .init(id: "day.plan", title: "Plan My Day", command: "plan my day", executionMode: .foreground, runtimeStatus: .reviewOnly),
        .init(id: "meeting.brief", title: "Pre-Meeting Brief", command: "prepare meeting", executionMode: .foreground, runtimeStatus: .implemented),
        .init(id: "research.quick", title: "Quick Research", command: "quick research", executionMode: .foreground, runtimeStatus: .reviewOnly),
        .init(id: "brain.save", title: "Save to Be Brain", command: "remember this", executionMode: .foreground, runtimeStatus: .implemented),
        .init(id: "brain.recall", title: "Recall from Be Brain", command: "search my Brain", executionMode: .foreground, runtimeStatus: .implemented),
        .init(id: "launcher.command", title: "Run BeLauncher Command", command: "", executionMode: .foreground, runtimeStatus: .implemented),
    ]

    public static func definition(id: String) -> BELAppIntentDefinition? {
        curated.first { $0.id == id }
    }

    public static func deepLink(actionID: String, query: String? = nil) -> URL? {
        guard let definition = definition(id: actionID) else { return nil }
        var components = URLComponents()
        components.scheme = "belauncher"
        components.host = "intent"
        components.path = "/\(definition.id)"
        if let query, !query.isEmpty {
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        }
        return components.url
    }

    public static func actionID(from url: URL) -> String? {
        guard url.scheme == "belauncher", url.host == "intent" else { return nil }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !id.isEmpty, definition(id: id) != nil else { return nil }
        return id
    }
}
