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
    case bookmark
    case window
    case shortcut
    case memory
    /// Something the brain recalled by meaning, from anywhere it was indexed.
    case recall
    case pendingCommit
    case answer
    case mission
    case agent
    case process

    public var label: String {
        switch self {
        case .application: "App"
        case .snippet: "Snippet"
        case .clipboard: L("Clipboard")
        case .workflow: L("Search")
        case .calculation: L("Result")
        case .file: L("File")
        case .flow: L("Flow")
        case .system: L("System")
        case .bookmark: L("Link")
        case .window: L("Window")
        case .shortcut: L("Shortcut")
        case .memory: L("Memory")
        case .recall: L("Recollection")
        case .pendingCommit: L("To confirm")
        case .answer: L("Answer")
        case .mission: L("Mission")
        case .agent: L("Command")
        case .process: L("Process")
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
        case .bookmark: "bookmark"
        case .window: "macwindow"
        case .shortcut: "square.stack.3d.up"
        case .memory: "brain"
        case .recall: "sparkle.magnifyingglass"
        case .pendingCommit: "checkmark.seal"
        case .answer: "text.bubble"
        case .mission: "wand.and.stars"
        case .agent: "terminal"
        case .process: "gauge.with.needle"
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
    /// A file the result can be *shown* as. Carried on the result rather than resolved later so a
    /// grid of clipboard cards can render every thumbnail, not only the selected one.
    public let previewPath: String
    /// Stable BEL identity, when this result came from the shared action catalogue.
    public let actionID: String?

    public init(id: String, kind: ResultKind, title: String, subtitle: String,
                score: Int, matched: [Int], payload: String, recordID: Int64 = 0,
                completion: String? = nil, previewPath: String = "", actionID: String? = nil) {
        self.previewPath = previewPath
        self.actionID = actionID
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
    /// Browser bookmarks and common folders.
    public var shortcuts: [Shortcut]
    /// Names of the user's own Shortcuts. The escape hatch that needs no plugin system.
    public var systemShortcuts: [String]
    /// What the brain currently holds as true, plus anything waiting to be confirmed.
    public var memories: [MemoryObject]
    public var pendingCommits: [MemoryCommit]
    public var events: [CalendarEvent]
    /// The outcomes installed on this Mac, which is what `/` offers.
    public var packs: [OutcomePack]
    /// Operational memory: what was worked on, and how it is connected.
    public var workNodes: [WorkNode]
    public var workEdges: [WorkEdge]
    /// What is running right now, read only when the person asks for it.
    public var processes: [RunningProcess]
    /// Saved arrangements of windows.
    public var workspaces: [Workspace]
    /// What the app has learned about how this person works.
    public var traits: [Trait]
    public var notes: [QuickNote.Record]

    public init(applications: [Application] = [], snippets: [Snippet] = [],
                workflows: [Workflow] = [], clips: [Clip] = [], flows: [Flow] = [],
                applicationUses: [String: Int] = [:], aliases: [String: String] = [:],
                shortcuts: [Shortcut] = [], systemShortcuts: [String] = [],
                memories: [MemoryObject] = [], pendingCommits: [MemoryCommit] = [],
                events: [CalendarEvent] = [], packs: [OutcomePack] = [],
                workNodes: [WorkNode] = [], workEdges: [WorkEdge] = [], traits: [Trait] = [],
                processes: [RunningProcess] = [], workspaces: [Workspace] = [],
                notes: [QuickNote.Record] = []) {
        self.applications = applications
        self.snippets = snippets
        self.workflows = workflows
        self.clips = clips
        self.flows = flows
        self.applicationUses = applicationUses
        self.aliases = aliases
        self.shortcuts = shortcuts
        self.systemShortcuts = systemShortcuts
        self.memories = memories
        self.pendingCommits = pendingCommits
        self.events = events
        self.packs = packs
        self.workNodes = workNodes
        self.workEdges = workEdges
        self.traits = traits
        self.processes = processes
        self.workspaces = workspaces
        self.notes = notes
    }
}

public enum SearchEngine {
    public static let resultLimit = 8

    public static func brainLaunchpadResults(limit: Int = 8) -> [SearchResult] {
        [
            SearchResult(
                id: "brain-open", kind: .system, title: L("Open your brain"),
                subtitle: L("See the graph, recent work and what needs correcting"),
                score: 101_000, matched: [], payload: SystemCommand.Kind.openBrain.rawValue,
                actionID: "brain.open"
            ),
            SearchResult(
                id: "brain-ask", kind: .answer, title: L("Ask your brain"),
                subtitle: L("Start with a question about decisions, people, projects or tasks"),
                score: 100_990, matched: [], payload: "",
                completion: L("what did we decide about ")
            ),
            SearchResult(
                id: "brain-remember", kind: .answer, title: L("Keep something in the brain"),
                subtitle: L("Write one sentence. It stays as a proposal until you confirm it"),
                score: 100_980, matched: [], payload: "",
                completion: L("remember that ")
            ),
            SearchResult(
                id: "brain-prepare", kind: .answer, title: L("Get briefed before a meeting"),
                subtitle: L("Pulls together decisions, commitments and recent context"),
                score: 100_970, matched: [], payload: "",
                completion: L("prepare me for ")
            ),
            SearchResult(
                id: "brain-decide", kind: .answer, title: L("Decide with the brain"),
                subtitle: L("Ask what is still in force before choosing"),
                score: 100_960, matched: [], payload: "",
                completion: L("what did we decide about ")
            ),
            SearchResult(
                id: "brain-act", kind: .answer, title: L("Run a mission"),
                subtitle: L("Plan, approve, execute, then get a receipt"),
                score: 100_950, matched: [], payload: "",
                completion: "/"
            ),
            SearchResult(
                id: "brain-note", kind: .answer, title: L("New quick note"),
                subtitle: L("Write freely and save it to your inbox as Markdown"),
                score: 100_930, matched: [], payload: ""
            ),
            SearchResult(
                id: "brain-pulse", kind: .answer, title: L("Ask for Pulse"),
                subtitle: L("See what BeBrain thinks you should be looking at"),
                score: 100_940, matched: [], payload: "",
                completion: L("pulse")
            ),
        ].prefix(limit).map { $0 }
    }

    public static func search(
        _ rawQuery: String,
        in input: SearchInput,
        calculation: CalculationResult? = nil,
        files: [FoundFile] = [],
        limit: Int = resultLimit
    ) -> [SearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }

        var pinned: [SearchResult] = []

        if wantsBrainLaunchpad(query) {
            pinned += brainLaunchpadResults()
        }

        if QuickNote.isTrigger(query) {
            pinned.append(SearchResult(
                id: "new-note", kind: .answer, title: L("Write a quick note"),
                subtitle: L("A multiline Markdown note saved in your inbox"),
                score: 100_100, matched: [], payload: ""
            ))
        }

        let foldedQuery = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if ["notas", "mis notas", "quick notes", "inbox"].contains(foldedQuery) {
            return input.notes.prefix(limit).enumerated().map { index, note in
                SearchResult(id: "note-file-\(index)", kind: .file, title: note.title,
                             subtitle: note.excerpt, score: 99_950 - index,
                             matched: [], payload: note.path)
            }
        }

        // A slash is an instruction, not a search. It is unambiguous on purpose: a launcher whose
        // box does both has to be able to tell "research" the word from "/research" the command,
        // and guessing from the words is how an agent fires because somebody typed a noun.
        let commands = input.packs.map(\.command)
        if query.hasPrefix("/") {
            let slash = query.dropFirst().lowercased()
            if slash == "nota" || slash == "note" || slash.hasPrefix("nota ") || slash.hasPrefix("note ") {
                let argument = slash.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                return [SearchResult(id: "new-note", kind: .answer,
                                     title: L("Write a quick note"),
                                     subtitle: L("Open the Markdown note editor"), score: 100_000,
                                     matched: [], payload: argument, completion: argument.isEmpty ? "/nota " : nil)]
            }
            if slash == "recordar" || slash == "remember" {
                return [SearchResult(id: "slash-remember", kind: .answer,
                                     title: L("Keep something in the brain"),
                                     subtitle: L("Write the fact you want to confirm"), score: 100_000,
                                     matched: [], payload: "", completion: "remember that ")]
            }
            if slash == "brain" || slash == "grafo" {
                return [SearchResult(id: "brain-open", kind: .system,
                                     title: L("Open your brain"),
                                     subtitle: L("Graph, reader and recent work"), score: 100_000,
                                     matched: [], payload: SystemCommand.Kind.openBrain.rawValue,
                                     actionID: "brain.open")]
            }
            if slash == "snippet" || slash == "snippets" {
                return input.snippets.prefix(limit).enumerated().map { index, snippet in
                    SearchResult(id: "snippet-\(snippet.id)", kind: .snippet,
                                 title: snippet.title,
                                 subtitle: "\(snippet.keyword) · \(preview(snippet.body))",
                                 score: 100_000 - index, matched: [], payload: snippet.body,
                                 recordID: snippet.id)
                }
            }
            if let (command, argument) = AgentCommand.parse(query, in: commands) {
                return [SearchResult(
                    id: "agent-\(command.id)", kind: .agent, title: command.title,
                    subtitle: argument.isEmpty ? command.summary : argument,
                    score: 100_000, matched: [], payload: command.id + "\u{1F}" + argument
                )]
            }
            return AgentCommand.suggestions(for: query, in: commands).map { command in
                SearchResult(
                    id: "agent-\(command.id)", kind: .agent, title: "/\(command.verb)",
                    subtitle: command.summary, score: 100_000, matched: [],
                    payload: command.id + "\u{1F}", completion: "/\(command.verb) "
                )
            }
        }

        // Paste a path, press Enter, you are there. Above everything, because someone who just
        // pasted an absolute path is not searching for an app whose name contains a slash.
        if let target = GoToPath.resolve(query) {
            pinned.append(SearchResult(
                id: "goto", kind: target.isDirectory ? .file : .file,
                title: target.exists ? "Ir a \(target.name)" : "No existe",
                subtitle: target.exists ? target.path : GoToPath.explain(target),
                score: 100_500, matched: [],
                payload: target.exists ? target.path : "",
                completion: target.completion
            ))
        }

        // Whole arrangements of windows: the thing people buy a separate app for.
        if let intent = WorkspaceLayouts.Intent.detect(query) {
            switch intent {
            case .save(let name):
                pinned.append(SearchResult(
                    id: "workspace-save", kind: .window,
                    title: L("Save this window layout as “%@”", name),
                    subtitle: L("Where every window is, on which display and how big"),
                    score: 99_870, matched: [], payload: "save:\(name)"
                ))
            case .restore(let name):
                for workspace in input.workspaces
                where workspace.id.hasPrefix(name.lowercased()) {
                    pinned.append(SearchResult(
                        id: "workspace-\(workspace.id)", kind: .window,
                        title: L("Place “%@”", workspace.name), subtitle: workspace.summary,
                        score: 99_870, matched: [], payload: "restore:\(workspace.name)"
                    ))
                }
            case .list:
                for workspace in input.workspaces {
                    pinned.append(SearchResult(
                        id: "workspace-\(workspace.id)", kind: .window,
                        title: workspace.name, subtitle: workspace.summary,
                        score: 99_870, matched: [], payload: "restore:\(workspace.name)"
                    ))
                }
            }
        }

        // A note is written the moment you press Enter: no confirmation, because it is yours.
        if let note = QuickNote.text(from: query) {
            pinned.append(SearchResult(
                id: "note", kind: .answer, title: L("Save the note"),
                subtitle: note, score: 99_900, matched: [], payload: note
            ))
        }

        // Keeping the Mac awake, which is a whole app on most Macs.
        if let offers = StayAwake.offers(for: query) {
            for offer in offers {
                pinned.append(SearchResult(
                    id: "awake-\(offer.minutes.map(String.init) ?? "forever")", kind: .system,
                    title: L("Keep the Mac awake · %@", offer.label),
                    subtitle: offer.minutes == nil
                        ? L("Until you turn it off from the menu bar")
                        : L("It switches itself off when it finishes"),
                    score: 99_850, matched: [],
                    payload: "awake:\(offer.minutes.map(String.init) ?? "")"
                ))
            }
        }

        // What is eating the Mac. Pinned above everything because someone typing this has a
        // fan spinning and is not looking for an app called "cpu".
        if let (order, filter) = ProcessList.order(for: query) {
            let top = ProcessList.top(input.processes, order: order, filter: filter)
            if top.isEmpty, !input.processes.isEmpty {
                pinned.append(SearchResult(
                    id: "process-none", kind: .answer,
                    title: filter.isEmpty ? L("Nothing is working harder than it should")
                        : L("Nothing called “%@”", filter),
                    subtitle: order.label, score: 99_800, matched: [], payload: ""
                ))
            }
            for process in top {
                pinned.append(SearchResult(
                    id: "process-\(process.id)", kind: .process, title: process.name,
                    subtitle: ProcessList.subtitle(for: process, order: order),
                    score: 99_800, matched: [], payload: String(process.id),
                    recordID: Int64(process.id)
                ))
            }
        }

        // Operational memory: what you were doing, as opposed to what the company believes.
        if let intent = WorkQuery.Intent.detect(query) {
            let answer: WorkQuery.Answer
            switch intent {
            case .promisedTo(let name):
                answer = WorkQuery.promised(to: name, nodes: input.workNodes,
                                            edges: input.workEdges, memories: input.memories)
            case .lastAbout(let subject):
                answer = WorkQuery.last(about: subject, nodes: input.workNodes,
                                        edges: input.workEdges)
            case .resumeBefore:
                answer = WorkQuery.resume(nodes: input.workNodes, meetings: input.events)
            case .about(let name):
                answer = WorkQuery.about(name, nodes: input.workNodes, edges: input.workEdges)
            }
            pinned.append(SearchResult(
                id: "work-answer", kind: .answer, title: answer.headline,
                subtitle: answer.nodes.first?.name ?? L("Working memory"),
                score: 99_500, matched: [], payload: answer.body
            ))
            // The things it found are offered directly, so "abre lo último de Atlas" opens it.
            for node in answer.nodes.prefix(4) where !node.target.isEmpty {
                pinned.append(SearchResult(
                    id: "work-\(node.id)", kind: node.kind == .file ? .file : .bookmark,
                    title: node.name, subtitle: node.detail, score: 99_400, matched: [],
                    payload: node.target
                ))
            }
        }

        // A question for the brain wins outright: the user asked something, not searched.
        switch BrainQuery.Intent.detect(query) {
        case .whatDidWeDecide(let topic):
            let answer = BrainQuery.whatDidWeDecide(topic: topic, in: input.memories)
            pinned.append(answerResult(answer, id: "answer-decide"))
        case .prepare(let subject):
            let answer = BrainQuery.prepare(subject: subject, in: input.memories, events: input.events)
            pinned.append(answerResult(answer, id: "answer-prepare"))
        case .remember(let text):
            pinned.append(SearchResult(
                id: "answer-remember", kind: .answer, title: "Recordar: \(text)",
                subtitle: L("It is kept as a proposal until you confirm it"),
                score: 100_000, matched: [], payload: text
            ))
        case .pulse:
            let signals = Pulse.signals(for: input.memories, traits: input.traits)
            pinned.append(SearchResult(
                id: "answer-pulse", kind: .answer,
                title: signals.isEmpty ? L("Nothing to flag")
                       : L("%@ thing(s) to look at", String(signals.count)),
                subtitle: signals.first?.headline ?? L("The brain is in order"),
                score: 100_000, matched: [], payload: Pulse.render(signals)
            ))

        case .none:
            // Typing what you want is the whole point of a launcher. "traducir esto", "resume",
            // "corrige" now surface directly instead of hiding behind select-then-⌘K, which is a
            // ritual nobody guesses and everybody has to be told.
            // Not a question: it might still be something the app knows how to carry out. But a
            // mission is our inference, and anything the user built themselves outranks it — if
            // they named a flow "enfoque", "enfoque" means their flow, full stop.
            let userOwned = Set(
                input.flows.map(\.keyword)
                + input.workflows.map(\.keyword)
                + input.snippets.map(\.keyword)
                + input.systemShortcuts.map { $0.lowercased() }
                + input.shortcuts.map { Phrases.fold($0.title) }
                + Array(input.aliases.keys)
            )
            let folded = query.lowercased().trimmingCharacters(in: .whitespaces)
            let collides = userOwned.contains(folded)
                || input.systemShortcuts.contains { $0.caseInsensitiveCompare(folded) == .orderedSame }

            // AI verbs are ordinary language, not slash commands. Keep the user's own flow or
            // shortcut in charge when it owns the same keyword; otherwise "resume esto" and
            // "corrige lo que copié" should reach the selected text without requiring ⌘K.
            if !collides, let typed = AIVerb.typed(query) {
                let pronouns = Set(["esto", "this", "it", "lo", "eso", "that"])
                let argument = Phrases.fold(typed.argument)
                let copied = input.clips.first(where: { $0.kind == .text })?.text ?? ""
                let source = typed.argument.isEmpty || pronouns.contains(argument) ? copied : typed.argument
                if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pinned.append(SearchResult(
                        id: "verb-\(typed.verb.id)", kind: .answer, title: typed.verb.title,
                        subtitle: typed.argument.isEmpty || pronouns.contains(argument)
                            ? L("on the last thing you copied · %@", preview(source))
                            : preview(source),
                        score: 100_200, matched: [],
                        payload: typed.verb.id + "\u{1F}" + source,
                        actionID: "ai.verb.\(typed.verb.id)"))
                }
            }

            // One catalogue resolves both native and AI actions. The payload keeps the existing
            // execution format until LauncherModel is fully migrated; actionID is the stable
            // identity used by new UI, receipts and later App Intents.
            if !collides, let match = BELActionResolver.resolve(query),
               let definition = BELActionCatalog.named(match.actionID),
               definition.availability == .implemented,
               !pinned.contains(where: { $0.actionID == definition.id }) {
                if definition.kind == .native,
                   let rawKind = BELActionCatalog.systemCommandKind(for: definition.id),
                   let command = SystemCommand.all.first(where: { $0.kind.rawValue == rawKind }) {
                    pinned.append(SearchResult(
                        id: "bel-\(definition.id)", kind: .system, title: command.title,
                        subtitle: command.needsConfirmation ? L("Asks you first") : L("System command"),
                        score: 100_120 + match.confidence, matched: [], payload: rawKind,
                        actionID: definition.id))
                } else if definition.kind == .native,
                          ["files.open", "files.reveal", "files.move_to_trash"].contains(definition.id),
                          !match.argument.isEmpty {
                    let path = (match.argument as NSString).expandingTildeInPath
                    let name = (path as NSString).lastPathComponent
                    pinned.append(SearchResult(
                        id: "bel-(definition.id)", kind: .file,
                        title: definition.titleKey == "Move file to Trash"
                            ? L("Move %@ to the trash", name) : name,
                        subtitle: L(definition.titleKey),
                        score: 100_120 + match.confidence, matched: [], payload: path,
                        actionID: definition.id))
                } else if definition.kind == .native {
                    let argument = match.argument
                    let payload = "bel:\(definition.id)\u{1F}\(argument)"
                    pinned.append(SearchResult(
                        id: "bel-\(definition.id)", kind: .system,
                        title: L(definition.titleKey),
                        subtitle: definition.requiredCapabilities.isEmpty
                            ? L("Local action") : L("Needs permission if it is not granted"),
                        score: 100_120 + match.confidence, matched: [], payload: payload,
                        actionID: definition.id))
                } else if definition.kind == .ai,
                          let legacyID = BELActionCatalog.legacyAIVerbID(for: definition.id),
                          let verb = AIVerb.named(legacyID) {
                    let source = match.argument.isEmpty
                        ? (input.clips.first(where: { $0.kind == .text })?.text ?? "")
                        : match.argument
                    if !source.isEmpty {
                        pinned.append(SearchResult(
                            id: "verb-\(legacyID)", kind: .answer, title: verb.title,
                            subtitle: match.argument.isEmpty
                                ? L("on the last thing you copied · %@", preview(source))
                                : preview(source),
                            score: 99_100 + match.confidence, matched: [],
                            payload: legacyID + "\u{1F}" + source, actionID: definition.id))
                    }
                }
            }

            // The missions that turn notes into memory work on what you just copied. Planning
            // them without it produced steps that were guaranteed to do nothing.
            let clipboard = input.clips.first(where: { $0.kind == .text })?.text ?? ""
            if !collides, let mission = MissionPlanner.plan(query, clipboard: clipboard) {
                pinned.append(SearchResult(
                    id: "mission-\(mission.id)", kind: .mission, title: mission.intent,
                    subtitle: mission.needsApproval
                        ? L("%@ steps · you see the plan before anything is touched", String(mission.steps.count))
                        : "\(mission.steps.count) pasos",
                    score: 95_000, matched: [], payload: mission.intent
                ))
            }
        }

        if let calculation {
            pinned.append(SearchResult(
                id: "calc", kind: .calculation, title: calculation.display,
                subtitle: calculation.detail + " · " + L("↩ copies it"),
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
        // Folded once for the whole search instead of once per candidate: with a real bookmark
        // file this was the difference between 95 ms and a usable keystroke.
        let needle = Fuzzy.folded(query)
        let needleMask = Fuzzy.mask(needle)

        // An alias is an exact instruction, so it wins outright: typing "nav" means that app.
        let aliasTarget = input.aliases[query.lowercased()]

        for application in input.applications {
            guard !Fuzzy.cannotMatch(needleMask: needleMask, candidateMask: application.mask),
                  let match = Fuzzy.match(needle: needle, hay: application.foldedName) else { continue }
            let uses = input.applicationUses[application.path] ?? 0
            results.append(SearchResult(
                id: "app-\(application.path)", kind: .application, title: application.name,
                subtitle: application.path,
                score: match.score + 30 + min(uses * 3, 45), matched: match.matched,
                payload: application.path
            ))
        }

        results += matchShortcuts(input.shortcuts, needle: needle, needleMask: needleMask)

        // The brain answers first when it has something: a decision beats a bookmark.
        for memory in input.memories {
            let haystack = Fuzzy.folded(memory.statement + " " + memory.entities.joined(separator: " "))
            guard let match = Fuzzy.match(needle: needle, hay: haystack) else { continue }
            results.append(SearchResult(
                id: "memory-\(memory.id)", kind: .memory, title: memory.statement,
                subtitle: memorySubtitle(memory),
                score: match.score + 60, matched: [], payload: memory.id
            ))
        }

        for commit in input.pendingCommits {
            guard let match = Fuzzy.match(needle: needle, hay: Fuzzy.folded(commit.object.statement))
            else { continue }
            results.append(SearchResult(
                id: "commit-\(commit.id)", kind: .pendingCommit, title: commit.object.statement,
                subtitle: commit.conflicts.isEmpty
                    ? L("Proposal · confirm or discard")
                    : L("Proposal · would replace %@ memory/memories", String(commit.conflicts.count)),
                // A large, deliberate bonus: something waiting on your decision should not lose
                // to a settled memory just because the wording matched better.
                score: match.score + 200, matched: [], payload: commit.id
            ))
        }

        for name in input.systemShortcuts {
            guard let match = Fuzzy.match(needle: needle, hay: Fuzzy.folded(name)) else { continue }
            results.append(SearchResult(
                id: "shortcut-run-\(name)", kind: .shortcut, title: name,
                subtitle: L("macOS Shortcut"), score: match.score + 15, matched: match.matched,
                payload: name
            ))
        }

        for (command, score) in WindowCommand.search(query) {
            results.append(SearchResult(
                id: "window-\(command.id)", kind: .window, title: command.title,
                subtitle: L("Places the active window"), score: score, matched: [],
                payload: command.layout.rawValue
            ))
        }

        for (command, score) in SystemCommand.search(query) {
            results.append(SearchResult(
                id: "system-\(command.id)", kind: .system, title: command.title,
                subtitle: command.needsConfirmation ? L("Asks you first") : L("System command"),
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
                subtitle: clipSubtitle(clip),
                score: match.score - 10 + (clip.isPinned ? 25 : 0), matched: [],
                payload: clip.text, recordID: clip.id,
                previewPath: clip.assetPath.isEmpty && clip.kind == .file
                    ? clip.text : clip.assetPath
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
        let visible = Array((pinned + ordered).prefix(limit))
        if visible.isEmpty, isNaturalLanguage(query) {
            return [SearchResult(
                id: "brain-question", kind: .answer,
                title: L("Ask your Brain about %@", query),
                subtitle: L("Search your local knowledge and show the sources"),
                score: 100_000, matched: [], payload: query
            )]
        }
        return visible
    }

    private static func isNaturalLanguage(_ query: String) -> Bool {
        let words = query.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        guard words.count >= 2 else { return query.hasSuffix("?") }
        let first = Phrases.fold(String(words[0]))
        let questionWords = Set([
            "que", "como", "donde", "cuando", "porque", "por", "quien",
            "what", "how", "where", "when", "why", "who", "can"
        ])
        return query.hasSuffix("?") || questionWords.contains(first)
            || words.count >= 4
    }

    private static func wantsBrainLaunchpad(_ query: String) -> Bool {
        guard BrainQuery.Intent.detect(query) == .none else { return false }
        let folded = Phrases.fold(query)
        let words = Set(folded.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let triggers: Set<String> = ["brain", "cerebro", "memoria", "memory", "recall", "recordar", "remember"]
        return !words.isDisjoint(with: triggers)
    }

    /// Recent clips shown when the window opens with an empty query. Unlike typed search, this is
    /// the clipboard history surface, so it keeps every clip the store retained.
    public static func recents(_ clips: [Clip], limit: Int = 1_000) -> [SearchResult] {
        clips.prefix(limit).map { clip in
            SearchResult(
                id: "clip-\(clip.id)", kind: .clipboard, title: preview(clip.text),
                subtitle: clipSubtitle(clip),
                score: 0, matched: [], payload: clip.text, recordID: clip.id,
                previewPath: clip.assetPath.isEmpty && clip.kind == .file
                    ? clip.text : clip.assetPath
            )
        }
    }

    static func answerResult(_ answer: BrainQuery.Answer, id: String) -> SearchResult {
        SearchResult(
            id: id, kind: .answer, title: answer.headline,
            subtitle: answer.gap ?? (answer.citations.count == 1
                ? L("1 source")
                : L("%@ sources", String(answer.citations.count))),
            score: 100_000, matched: [], payload: answer.body
        )
    }

    static func memorySubtitle(_ memory: MemoryObject) -> String {
        var parts = [memory.kind.rawValue.capitalized]
        if !memory.owner.isEmpty { parts.append(memory.owner) }
        if memory.status == .superseded { parts.append("sustituida") }
        if !memory.source.isEmpty { parts.append(memory.source) }
        return parts.joined(separator: " · ")
    }

    static func clipSubtitle(_ clip: Clip) -> String {
        var parts: [String] = []
        if clip.isPinned { parts.append("📌 Fijado") }
        switch clip.kind {
        case .image: parts.append("Imagen")
        case .file: parts.append(L("File"))
        case .link: parts.append("Enlace")
        case .text: break
        }
        parts.append(clip.sourceApp.isEmpty ? L("Clipboard") : L("Copied from %@", clip.sourceApp))
        return parts.joined(separator: " · ")
    }

    /// A real bookmark file can hold tens of thousands of entries, and scoring them one by one
    /// costs ~50 ms per keystroke on this machine — visible stutter. The work is embarrassingly
    /// parallel, so above a threshold it is split across cores; each chunk writes its own slot,
    /// so nothing is shared.
    static func matchShortcuts(
        _ shortcuts: [Shortcut], needle: [Character], needleMask: UInt32, keep: Int = resultLimit
    ) -> [SearchResult] {
        // Two passes on purpose. Scoring is cheap; building a result (string interpolation plus a
        // highlight array) is not, and with a real bookmark file almost every entry matches a
        // one-letter query. So: score everything, keep the best handful, build only those.
        func rate(_ index: Int) -> (index: Int, score: Int)? {
            let shortcut = shortcuts[index]
            guard !Fuzzy.cannotMatch(needleMask: needleMask, candidateMask: shortcut.mask) else {
                return nil
            }
            // Folders are few and behave like app names, so a subsequence is fine. Bookmarks are
            // tens of thousands, and a scattered match there is noise that buries the real answer.
            // A one-character query is contiguous by definition. Avoid scanning every bookmark
            // title twice on the worst launcher path; longer bookmark queries still use the
            // contiguous-run guard so scattered letters do not drown real results.
            if shortcut.source != .folder, needle.count > 1,
               !Fuzzy.containsRun(needle: needle, hay: shortcut.foldedTitle) {
                return nil
            }
            guard let score = Fuzzy.score(needle: needle, hay: shortcut.foldedTitle) else { return nil }
            return (index, score + (shortcut.source == .folder ? 12 : 8))
        }

        var rated: [(index: Int, score: Int)] = []
        let parallelThreshold = 2_000

        // Only the best `keep` entries can survive the final ranking. Trimming each worker's
        // local list before merging avoids sorting every bookmark on a one-letter query.
        func best(_ values: [(index: Int, score: Int)]) -> [(index: Int, score: Int)] {
            values.sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.index < rhs.index
            }.prefix(keep).map { $0 }
        }

        if shortcuts.count < parallelThreshold {
            rated = best((0..<shortcuts.count).compactMap(rate))
        } else {
            let chunkCount = min(ProcessInfo.processInfo.activeProcessorCount, 12)
            let chunkSize = (shortcuts.count + chunkCount - 1) / chunkCount
            var partial = [[(index: Int, score: Int)]](repeating: [], count: chunkCount)
            partial.withUnsafeMutableBufferPointer { buffer in
                nonisolated(unsafe) let slots = buffer
                DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                    let start = chunk * chunkSize
                    guard start < shortcuts.count else { return }
                    slots[chunk] = best((start..<min(start + chunkSize, shortcuts.count)).compactMap(rate))
                }
            }
            rated = partial.flatMap { $0 }
        }

        return rated
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.index < rhs.index
            }
            .prefix(keep)
            .map { entry in
                let shortcut = shortcuts[entry.index]
                let isFolder = shortcut.source == .folder
                return SearchResult(
                    id: "shortcut-\(shortcut.target)",
                    kind: isFolder ? .file : .bookmark,
                    title: shortcut.title,
                    subtitle: shortcut.target,
                    score: entry.score,
                    matched: Fuzzy.match(needle: needle, hay: shortcut.foldedTitle)?.matched ?? [],
                    payload: shortcut.target
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
