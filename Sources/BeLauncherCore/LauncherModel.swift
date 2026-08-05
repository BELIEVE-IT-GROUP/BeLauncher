import Foundation
import Observation

/// Keyboard-first state machine behind the command window.
/// It owns no UI, which is what makes the whole keyboard workflow testable end to end.
@MainActor
@Observable
public final class LauncherModel {

    public enum State: Equatable, Sendable {
        case loading
        case empty          // no query typed yet
        case results
        case noMatch
        case failed(String) // recoverable: the user can retry
    }

    public enum Key: Sendable {
        case up, down, enter, escape, tab
        /// ⌘↩ — runs the second action of the selected result, the platform convention.
        case secondaryAction
        /// ⌘K — opens the action panel for the selected result.
        case actionPanel
    }

    /// The window can be summoned straight into clipboard history (⌥C).
    public enum Mode: Sendable, Equatable {
        case all
        case clipboard
    }

    public enum Action: Equatable, Sendable {
        case launchApplication(path: String)
        case copyToClipboard(text: String, cursorOffset: Int?)
        case openURL(URL)
        case openFile(path: String)
        case revealInFinder(path: String)
        case runShortcut(name: String)
        case startTimer(minutes: Int, label: String)
        case wait(seconds: Double)
        /// A whole flow, already planned. The app layer walks it in order and honours waits.
        indirect case runFlow(steps: [Action])
        case openWith(path: String)
        case quickLook(path: String)
        case moveToTrash(path: String)
        case openSettings
        case systemCommand(String)
        case arrangeWindow(String)
        case remember(text: String, source: String)
        case confirmCommit(String)
        case discardCommit(String)
        case runVerb(id: String, text: String)
        case assignAlias(target: String, suggestion: String)
        indirect case runMission(Mission)
        indirect case missionCancelled(Mission)
        case dismiss
        /// Calls off a model request that is taking longer than the person is willing to wait.
        case cancelAI
    }

    public private(set) var state: State = .loading
    public private(set) var results: [SearchResult] = []
    public private(set) var selection: Int = 0
    /// Bumped every time the window is shown so the text field can re-take focus.
    public private(set) var focusToken: Int = 0
    public private(set) var mode: Mode = .all

    // MARK: - Action panel (⌘K)

    /// What a model is doing right now, so the window can show it instead of freezing.
    public enum AIState: Equatable, Sendable {
        case idle
        case working(String)
        case answer(verb: String, text: String)
        case failed(String)
    }

    public private(set) var aiState: AIState = .idle

    /// The mission waiting for approval, if any. Shown as a plan the user reads before anything
    /// runs; there is no path that starts a mission without this step.
    public private(set) var mission: Mission?

    public func approveMission() {
        guard var current = mission else { return }
        current.state = .running
        mission = current
        perform(.runMission(current))
        mission = nil
    }

    public func cancelMission() {
        guard var current = mission else { return }
        current.state = .cancelled
        mission = nil
        perform(.missionCancelled(current))
    }

    public func aiWorking(_ title: String) { aiState = .working(title) }
    public func aiAnswered(verb: String, text: String) { aiState = .answer(verb: verb, text: text) }
    public func aiFailed(_ message: String) { aiState = .failed(message) }
    public func clearAI() { aiState = .idle; perform(.cancelAI) }

    public private(set) var isActionPanelOpen = false
    public private(set) var actionSelection = 0
    public var actionQuery: String = "" {
        didSet { if actionQuery != oldValue { actionSelection = 0 } }
    }

    /// Verbs available for whatever is selected right now.
    public var actions: [ResultAction] {
        guard let selected else { return [] }
        return ActionRegistry.actions(for: selected)
    }

    public var visibleActions: [ResultAction] {
        ActionRegistry.filter(actions, query: actionQuery)
    }

    public var selectedAction: ResultAction? {
        visibleActions.indices.contains(actionSelection) ? visibleActions[actionSelection] : nil
    }

    /// The preview shown beside the list.
    public var detail: ResultDetail? {
        guard let selected, let input = try? dataSource() else { return nil }
        return DetailBuilder.detail(
            for: selected, snippets: input.snippets, flows: input.flows,
            clips: input.clips, memories: input.memories, commits: input.pendingCommits,
            expander: expanderFactory(), fileInfo: fileInfo
        )
    }

    public func openActionPanel() {
        guard selected != nil else { return }
        actionQuery = ""
        actionSelection = 0
        isActionPanelOpen = true
    }

    public func closeActionPanel() {
        isActionPanelOpen = false
        actionQuery = ""
    }

    public func selectAction(_ index: Int) {
        guard visibleActions.indices.contains(index) else { return }
        actionSelection = index
    }

    /// Runs an action by id, whichever route the user took to reach it.
    @discardableResult
    public func run(_ action: ResultAction) -> Bool {
        closeActionPanel()
        switch action.intent {
        case .run:
            return runSelected()
        case .reveal(let path):
            perform(.revealInFinder(path: path))
        case .openWith(let path):
            perform(.openWith(path: path))
        case .quickLook(let path):
            perform(.quickLook(path: path))
        case .copy(let text):
            perform(.copyToClipboard(text: text, cursorOffset: nil))
        case .paste(let text):
            perform(.copyToClipboard(text: text, cursorOffset: nil))
        case .saveClipAsSnippet(let text):
            perform(.copyToClipboard(text: text, cursorOffset: nil))
            perform(.openSettings)
            return true
        case .completeKeyword(let keyword):
            query = keyword
            return true
        case .openSettings:
            perform(.openSettings)
            return true
        case .moveToTrash(let path):
            perform(.moveToTrash(path: path))
        case .systemCommand(let kind):
            perform(.systemCommand(kind))
        case .remember(let text, let source):
            perform(.remember(text: text, source: source))
            return true
        case .confirmCommit(let id):
            perform(.confirmCommit(id))
            refresh()
            return true
        case .discardCommit(let id):
            perform(.discardCommit(id))
            refresh()
            return true
        case .runVerb(let id, let text):
            aiState = .working(AIVerb.named(id)?.title ?? "Pensando")
            perform(.runVerb(id: id, text: text))
            return true
        case .assignAlias(let target, let suggestion):
            perform(.assignAlias(target: target, suggestion: suggestion))
            return true
        case .deleteClip(let id):
            onDelete(.clipboard, id)
            refresh()
            return true
        case .setPinned(let pinned, let id):
            onPin(pinned, id)
            refresh()
            return true
        case .deleteSnippet(let id):
            onDelete(.snippet, id)
            refresh()
            return true
        case .deleteWorkflow(let id):
            onDelete(.workflow, id)
            refresh()
            return true
        case .deleteFlow(let id):
            onDelete(.flow, id)
            refresh()
            return true
        }
        perform(.dismiss)
        return true
    }

    public var query: String = "" {
        didSet { if query != oldValue { refresh() } }
    }

    public var isIndexing: Bool = false {
        didSet { if isIndexing != oldValue { refresh() } }
    }

    private let dataSource: @MainActor () throws -> SearchInput
    private let fileSearch: FileSearch
    private let fileInfo: @Sendable (String) -> [ResultDetail.Item]
    private let onDelete: @MainActor (ResultKind, Int64) -> Void
    private let onLaunch: @MainActor (String) -> Void
    private let onPin: @MainActor (Bool, Int64) -> Void
    private let expanderFactory: @MainActor () -> SnippetExpander
    private let perform: @MainActor (Action) -> Void
    private let recordUse: @MainActor (ResultKind, Int64) -> Void

    public init(
        dataSource: @escaping @MainActor () throws -> SearchInput,
        fileSearch: FileSearch = FileSearch(),
        fileInfo: @escaping @Sendable (String) -> [ResultDetail.Item] = { _ in [] },
        onLaunch: @escaping @MainActor (String) -> Void = { _ in },
        onPin: @escaping @MainActor (Bool, Int64) -> Void = { _, _ in },
        onDelete: @escaping @MainActor (ResultKind, Int64) -> Void = { _, _ in },
        expander: @escaping @MainActor () -> SnippetExpander = { SnippetExpander() },
        recordUse: @escaping @MainActor (ResultKind, Int64) -> Void = { _, _ in },
        perform: @escaping @MainActor (Action) -> Void
    ) {
        self.dataSource = dataSource
        self.fileSearch = fileSearch
        self.fileInfo = fileInfo
        self.onDelete = onDelete
        self.onLaunch = onLaunch
        self.onPin = onPin
        self.expanderFactory = expander
        self.recordUse = recordUse
        self.perform = perform
    }

    // MARK: - Lifecycle

    /// Called every time the window is summoned.
    public func activate(mode: Mode = .all) {
        self.mode = mode
        aiState = .idle
        mission = nil
        closeActionPanel()
        query = ""
        selection = 0
        focusToken += 1
        refresh()
    }

    public func retry() {
        refresh()
    }

    public func refresh() {
        guard !isIndexing else {
            state = .loading
            results = []
            return
        }
        do {
            let input = try dataSource()
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                results = SearchEngine.recents(input.clips)
                state = .empty
            } else if mode == .clipboard {
                results = SearchEngine.search(query, in: SearchInput(clips: input.clips))
                state = results.isEmpty ? .noMatch : .results
            } else {
                // ponytail: mdfind runs synchronously here. It only fires behind the explicit
                // "f " prefix and returns in a few ms; move it off the main actor if that stops
                // being true.
                let files = FileSearch.query(from: query).map { fileSearch.search($0) } ?? []
                results = SearchEngine.search(
                    query, in: input,
                    calculation: Calculator.evaluate(query),
                    files: files
                )
                state = results.isEmpty ? .noMatch : .results
            }
        } catch {
            results = []
            state = .failed("\(error)")
        }
        selection = min(selection, max(results.count - 1, 0))
        if isActionPanelOpen, results.isEmpty { closeActionPanel() }
    }

    // MARK: - Keyboard

    /// Returns true when the key was consumed.
    @discardableResult
    public func handle(_ key: Key) -> Bool {
        switch key {
        case .escape:
            // The panel closes first: escape means "back one level", not "give up".
            if isActionPanelOpen { closeActionPanel(); return true }
            perform(.dismiss)
            return true

        case .actionPanel:
            isActionPanelOpen ? closeActionPanel() : openActionPanel()
            return true
        case .down:
            if isActionPanelOpen {
                guard !visibleActions.isEmpty else { return true }
                actionSelection = (actionSelection + 1) % visibleActions.count
                return true
            }
            guard !results.isEmpty else { return true }
            selection = (selection + 1) % results.count
            return true
        case .up:
            if isActionPanelOpen {
                guard !visibleActions.isEmpty else { return true }
                actionSelection = (actionSelection - 1 + visibleActions.count) % visibleActions.count
                return true
            }
            guard !results.isEmpty else { return true }
            selection = (selection - 1 + results.count) % results.count
            return true
        case .tab:
            // Autocomplete a workflow keyword so the user can type its argument.
            guard let completion = selected?.completion else { return false }
            query = completion
            return true
        case .secondaryAction:
            guard let result = selected, let action = ActionRegistry.secondary(for: result) else { return false }
            return run(action)

        case .enter:
            if isActionPanelOpen, let action = selectedAction { return run(action) }
            // An answer on screen is what Return is about now.
            if case .answer(_, let text) = aiState {
                perform(.copyToClipboard(text: text, cursorOffset: nil))
                perform(.dismiss)
                return true
            }
            return runSelected()
        }
    }

    public var selected: SearchResult? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    public func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selection = index
    }

    @discardableResult
    public func runSelected() -> Bool {
        guard let result = selected else { return false }
        switch result.kind {
        case .application:
            onLaunch(result.payload)
            perform(.launchApplication(path: result.payload))
            perform(.dismiss)

        case .system:
            perform(.systemCommand(result.payload))
            perform(.dismiss)

        case .shortcut:
            perform(.runShortcut(name: result.payload))
            perform(.dismiss)

        case .memory:
            perform(.copyToClipboard(text: result.title, cursorOffset: nil))
            perform(.dismiss)

        case .mission:
            guard let planned = MissionPlanner.plan(result.payload) else { return false }
            mission = planned
            return true

        case .answer:
            // A typed verb carries "<verb id>\u{1F}<text>": the separator is a unit separator so it
            // can never collide with anything a person copied.
            if result.id.hasPrefix("verb-"),
               let split = result.payload.firstIndex(of: "\u{1F}") {
                perform(.runVerb(id: String(result.payload[..<split]),
                                 text: String(result.payload[result.payload.index(after: split)...])))
                return true
            }
            if result.id == "answer-remember" {
                perform(.remember(text: result.payload, source: "Escrito a mano"))
            } else {
                perform(.copyToClipboard(text: result.payload, cursorOffset: nil))
                perform(.dismiss)
            }

        case .pendingCommit:
            perform(.confirmCommit(result.payload))
            refresh()

        case .window:
            // Dismiss first: the front window must be the user's, not ours.
            perform(.dismiss)
            perform(.arrangeWindow(result.payload))

        case .bookmark:
            guard let url = URL(string: result.payload) else { return false }
            perform(.openURL(url))
            perform(.dismiss)

        case .clipboard, .calculation:
            perform(.copyToClipboard(text: result.payload, cursorOffset: nil))
            perform(.dismiss)

        case .file:
            perform(.openFile(path: result.payload))
            perform(.dismiss)

        case .snippet:
            let expanded = expanderFactory().expand(result.payload, query: query)
            recordUse(.snippet, result.recordID)
            perform(.copyToClipboard(text: expanded.text, cursorOffset: expanded.cursorOffset))
            perform(.dismiss)

        case .flow:
            guard let input = try? dataSource(),
                  let flow = input.flows.first(where: { $0.id == result.recordID }) else { return true }
            recordUse(.flow, result.recordID)
            perform(.runFlow(steps: FlowRunner.plan(flow, snippets: input.snippets, expander: expanderFactory())))

        case .workflow:
            guard !result.payload.isEmpty, let url = URL(string: result.payload) else {
                // Workflow selected without an argument: prime the query instead of failing.
                _ = handle(.tab)
                return true
            }
            recordUse(.workflow, result.recordID)
            perform(.openURL(url))
            perform(.dismiss)
        }
        return true
    }
}
