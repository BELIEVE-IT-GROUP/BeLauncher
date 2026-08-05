import Foundation

public enum ResultKind: String, Sendable, Codable, CaseIterable {
    case application
    case snippet
    case clipboard
    case workflow
    case calculation
    case file
    case flow
    case system

    public var label: String {
        switch self {
        case .application: "App"
        case .snippet: "Snippet"
        case .clipboard: "Clipboard"
        case .workflow: "Workflow"
        case .calculation: "Result"
        case .file: "File"
        case .flow: "Flow"
        case .system: "Sistema"
        }
    }

    public var symbol: String {
        switch self {
        case .application: "app.dashed"
        case .snippet: "text.quote"
        case .clipboard: "doc.on.clipboard"
        case .workflow: "bolt.horizontal"
        case .calculation: "equal.square"
        case .file: "doc"
        case .flow: "arrow.triangle.branch"
        case .system: "switch.2"
        }
    }
}

public struct SearchResult: Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: ResultKind
    public let title: String
    public let subtitle: String
    public let score: Int
    public let matched: [Int]
    /// App path, snippet body, clip text or resolved workflow URL — resolved by the action layer.
    public let payload: String
    public let recordID: Int64
    /// Text that Tab (or Enter on an incomplete workflow) writes into the search field.
    public let completion: String?

    public init(id: String, kind: ResultKind, title: String, subtitle: String,
                score: Int, matched: [Int], payload: String, recordID: Int64 = 0,
                completion: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.score = score
        self.matched = matched
        self.payload = payload
        self.recordID = recordID
        self.completion = completion
    }
}

public struct SearchInput: Sendable {
    public var applications: [Application]
    public var snippets: [Snippet]
    public var workflows: [Workflow]
    public var clips: [Clip]
    public var flows: [Flow]
    /// How often each application has been launched from here, so the list learns.
    public var applicationUses: [String: Int]
    /// User-defined aliases: typed text → exact result it should surface.
    public var aliases: [String: String]

    public init(applications: [Application] = [], snippets: [Snippet] = [],
                workflows: [Workflow] = [], clips: [Clip] = [], flows: [Flow] = [],
                applicationUses: [String: Int] = [:], aliases: [String: String] = [:]) {
        self.applications = applications
        self.snippets = snippets
        self.workflows = workflows
        self.clips = clips
        self.flows = flows
        self.applicationUses = applicationUses
        self.aliases = aliases
    }
}

public enum SearchEngine {
    public static let resultLimit = 8

    public static func search(
        _ rawQuery: String,
        in input: SearchInput,
        calculation: CalculationResult? = nil,
        files: [FoundFile] = [],
        limit: Int = resultLimit
    ) -> [SearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }

        // A calculation always wins: the user typed something only a calculator can answer.
        var pinned: [SearchResult] = []
        if let calculation {
            pinned.append(SearchResult(
                id: "calc", kind: .calculation, title: calculation.display,
                subtitle: "\(calculation.detail) · ↩ copies it",
                score: 100_000, matched: [], payload: calculation.raw
            ))
        }
        // Once the user typed the file prefix they are looking for files, so nothing else
        // is mixed in — an empty result reads as "no files", not as a pile of stale matches.
        if FileSearch.query(from: query) != nil {
            pinned += files.enumerated().map { index, file in
                SearchResult(
                    id: "file-\(file.path)", kind: .file, title: file.name,
                    subtitle: file.path, score: 90_000 - index, matched: [], payload: file.path
                )
            }
            return Array(pinned.prefix(limit))
        }

        // "gh swift concurrency" → run the `gh` workflow with the rest as its query.
        let words = query.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if words.count == 2, let workflow = input.workflows.first(where: { $0.keyword == words[0].lowercased() }) {
            let argument = String(words[1])
            let url = WorkflowURL.build(template: workflow.urlTemplate, query: argument, secret: Keychain.get(_:))
            return [SearchResult(
                id: "workflow-\(workflow.id)",
                kind: .workflow,
                title: "\(workflow.title): \(argument)",
                subtitle: url?.absoluteString ?? "This workflow’s URL template is invalid",
                score: 10_000,
                matched: [],
                payload: url?.absoluteString ?? "",
                recordID: workflow.id
            )]
        }

        var results: [SearchResult] = []

        // An alias is an exact instruction, so it wins outright: typing "nav" means that app.
        let aliasTarget = input.aliases[query.lowercased()]

        for application in input.applications {
            guard let match = Fuzzy.match(query: query, candidate: application.name) else { continue }
            let uses = input.applicationUses[application.path] ?? 0
            results.append(SearchResult(
                id: "app-\(application.path)", kind: .application, title: application.name,
                subtitle: application.path,
                score: match.score + 30 + min(uses * 3, 45), matched: match.matched,
                payload: application.path
            ))
        }

        for (command, score) in SystemCommand.search(query) {
            results.append(SearchResult(
                id: "system-\(command.id)", kind: .system, title: command.title,
                subtitle: command.needsConfirmation ? "Pide confirmación" : "Comando del sistema",
                score: score, matched: [], payload: command.kind.rawValue
            ))
        }

        for snippet in input.snippets {
            let byKeyword = Fuzzy.match(query: query, candidate: snippet.keyword)
            let byTitle = Fuzzy.match(query: query, candidate: snippet.title)
            guard let best = [byKeyword, byTitle].compactMap({ $0 }).max(by: { $0.score < $1.score }) else { continue }
            let bonus = (byKeyword?.score ?? 0) > (byTitle?.score ?? 0) ? 40 : 10
            results.append(SearchResult(
                id: "snippet-\(snippet.id)", kind: .snippet, title: snippet.title,
                subtitle: "\(snippet.keyword) · \(preview(snippet.body))",
                score: best.score + bonus + min(snippet.uses, 20), matched: [],
                payload: snippet.body, recordID: snippet.id
            ))
        }

        for workflow in input.workflows {
            let byKeyword = Fuzzy.match(query: query, candidate: workflow.keyword)
            let byTitle = Fuzzy.match(query: query, candidate: workflow.title)
            guard let best = [byKeyword, byTitle].compactMap({ $0 }).max(by: { $0.score < $1.score }) else { continue }
            results.append(SearchResult(
                id: "workflow-\(workflow.id)", kind: .workflow, title: workflow.title,
                subtitle: "\(workflow.keyword) · type a search term, then ↩",
                score: best.score + 20 + min(workflow.uses, 20), matched: [],
                payload: "", recordID: workflow.id, completion: "\(workflow.keyword) "
            ))
        }

        for flow in input.flows {
            let byKeyword = Fuzzy.match(query: query, candidate: flow.keyword)
            let byTitle = Fuzzy.match(query: query, candidate: flow.title)
            guard let best = [byKeyword, byTitle].compactMap({ $0 }).max(by: { $0.score < $1.score }) else { continue }
            results.append(SearchResult(
                id: "flow-\(flow.id)", kind: .flow, title: flow.title,
                subtitle: "\(flow.keyword) · \(flow.steps.count) step\(flow.steps.count == 1 ? "" : "s")",
                score: best.score + 45 + min(flow.uses, 20), matched: [],
                payload: "", recordID: flow.id
            ))
        }

        for clip in input.clips {
            guard let match = Fuzzy.match(query: query, candidate: clip.text) else { continue }
            results.append(SearchResult(
                id: "clip-\(clip.id)", kind: .clipboard, title: preview(clip.text),
                subtitle: clip.sourceApp.isEmpty ? "Clipboard" : "Copied from \(clip.sourceApp)",
                score: match.score - 10, matched: [], payload: clip.text, recordID: clip.id
            ))
        }

        var ordered = results.sorted { $0.score > $1.score }
        // An alias is an explicit instruction: its target goes first even when the fuzzy matcher
        // would never have surfaced it ("nav" bears no resemblance to "Safari").
        if let aliasTarget {
            if let index = ordered.firstIndex(where: { $0.payload == aliasTarget }) {
                ordered.insert(ordered.remove(at: index), at: 0)
            } else if let application = input.applications.first(where: { $0.path == aliasTarget }) {
                ordered.insert(SearchResult(
                    id: "app-\(application.path)", kind: .application, title: application.name,
                    subtitle: "alias · \(query.lowercased())", score: 50_000, matched: [],
                    payload: application.path
                ), at: 0)
            }
        }
        return Array((pinned + ordered).prefix(limit))
    }

    /// Recent clips shown when the window opens with an empty query.
    public static func recents(_ clips: [Clip], limit: Int = resultLimit) -> [SearchResult] {
        clips.prefix(limit).map { clip in
            SearchResult(
                id: "clip-\(clip.id)", kind: .clipboard, title: preview(clip.text),
                subtitle: clip.sourceApp.isEmpty ? "Clipboard" : "Copied from \(clip.sourceApp)",
                score: 0, matched: [], payload: clip.text, recordID: clip.id
            )
        }
    }

    static func preview(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flattened.count > 70 ? String(flattened.prefix(70)) + "…" : flattened
    }
}
