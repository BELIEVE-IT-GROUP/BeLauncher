import Foundation

/// A named chain of steps: "enfoque" → silence notifications, open Notion and Terminal,
/// start a 50 minute timer.
///
/// Steps come from a closed catalogue that BeLauncher implements itself. There is no shell,
/// no script file and no arbitrary code — the only escape hatch is running a Shortcut the user
/// already built and authorised in Apple's own Shortcuts app.
public struct Flow: Sendable, Equatable, Codable, Identifiable {
    public var id: Int64
    public var keyword: String
    public var title: String
    public var steps: [FlowStep]
    public var uses: Int

    public init(id: Int64 = 0, keyword: String, title: String, steps: [FlowStep], uses: Int = 0) {
        self.id = id
        self.keyword = keyword
        self.title = title
        self.steps = steps
        self.uses = uses
    }
}

public enum FlowStep: Sendable, Equatable, Codable {
    case openApp(path: String)
    case openURL(url: String)
    case openFile(path: String)
    case copyText(text: String)
    case runSnippet(keyword: String)
    /// Runs a Shortcut by name via Apple's `shortcuts` tool: this is how a flow can set a
    /// Focus, toggle Do Not Disturb or touch anything else macOS exposes only through Shortcuts.
    case runShortcut(name: String)
    /// One of the app's own system commands. A flow could open apps and set timers but not
    /// silence notifications, which is the first step of the focus flow on the landing page.
    case systemCommand(kind: String)
    case timer(minutes: Int, label: String)
    case wait(seconds: Double)

    public var summary: String {
        switch self {
        case .openApp(let path): "Open \((path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""))"
        case .openURL(let url): "Open \(url)"
        case .openFile(let path): "Open \((path as NSString).lastPathComponent)"
        case .copyText(let text): "Copy “\(text.prefix(30))\(text.count > 30 ? "…" : "")”"
        case .runSnippet(let keyword): "Paste snippet \(keyword)"
        case .runShortcut(let name): "Run shortcut “\(name)”"
        case .systemCommand(let kind):
            SystemCommand.all.first { $0.kind.rawValue == kind }?.title ?? kind
        case .timer(let minutes, let label): "Timer \(minutes) min · \(label)"
        case .wait(let seconds): "Wait \(Calculator.format(seconds))s"
        }
    }

    public var symbol: String {
        switch self {
        case .openApp: "app.dashed"
        case .openURL: "link"
        case .openFile: "doc"
        case .copyText: "doc.on.clipboard"
        case .runSnippet: "text.quote"
        case .runShortcut: "square.stack.3d.up"
        case .systemCommand(let kind):
            SystemCommand.all.first { $0.kind.rawValue == kind }?.symbol ?? "switch.2"
        case .timer: "timer"
        case .wait: "hourglass"
        }
    }
}

public enum FlowError: Error, Equatable, CustomStringConvertible {
    case noSteps
    case badURL(String)
    case badShortcutName(String)
    case badTimer(Int)
    case unknownSnippet(String)
    case unknownSystemCommand(String)

    public var description: String {
        switch self {
        case .noSteps: "A flow needs at least one step."
        case .badURL(let url): "“\(url)” is not a valid http, https or mailto URL."
        case .badShortcutName(let name): "“\(name)” is not a usable Shortcut name."
        case .badTimer(let minutes): "A timer must be between 1 and 1440 minutes (got \(minutes))."
        case .unknownSnippet(let keyword): "There is no snippet with the keyword “\(keyword)”."
        case .unknownSystemCommand(let kind): "There is no system command called “\(kind)”."
        }
    }
}

public enum FlowValidator {
    /// Shortcut names travel as a process argument, never through a shell, but they are still
    /// checked: control characters and newlines have no business in a name.
    public static func validate(_ steps: [FlowStep], snippetKeywords: Set<String> = []) throws {
        guard !steps.isEmpty else { throw FlowError.noSteps }
        for step in steps {
            switch step {
            case .openURL(let url):
                guard WorkflowURL.build(template: url, query: "") != nil else { throw FlowError.badURL(url) }
            case .runShortcut(let name):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.count <= 120,
                      !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                else { throw FlowError.badShortcutName(name) }
            case .timer(let minutes, _):
                guard (1...1440).contains(minutes) else { throw FlowError.badTimer(minutes) }
            case .runSnippet(let keyword):
                guard snippetKeywords.isEmpty || snippetKeywords.contains(keyword.lowercased()) else {
                    throw FlowError.unknownSnippet(keyword)
                }
            case .systemCommand(let kind):
                // A flow that names a command the app does not have would fail silently at the
                // step, which is the worst place to discover a typo.
                guard SystemCommand.all.contains(where: { $0.kind.rawValue == kind }) else {
                    throw FlowError.unknownSystemCommand(kind)
                }
            case .openApp, .openFile, .copyText, .wait:
                break
            }
        }
    }
}
