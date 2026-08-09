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

    public enum Action: Equatable, Sendable, Codable {
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
        /// Opens a canvas: a small workspace of blocks for outcomes that are a set of pieces
        /// rather than one answer.
        case openCanvas(template: String, brief: String)
        /// Hands an outcome to the agent runner, which puts it in the tray.
        case runAgent(id: String, argument: String)
        /// Asks a process to quit, the way ⌘Q does.
        case quitProcess(pid: String)
        /// Ends it whether it likes it or not. Loses unsaved work, so it is never on a key.
        case forceQuit(pid: String)
        /// Keeps the Mac awake for a while, or until told otherwise.
        case stayAwake(minutes: Int?)
        /// Remembers where every window is right now, under a name.
        case saveWorkspace(name: String)
        /// Puts them all back.
        case restoreWorkspace(name: String)
        /// Writes a scratch note straight to the vault's inbox.
        ///
        /// No confirmation, unlike a memory: a note is yours, not something the company now
        /// believes. That distinction is what lets this be one keystroke.
        case writeNote(text: String)
        case createSnippet(text: String)
        /// Opens a multi-line note editor from the launcher.
        case openQuickNoteEditor(initialText: String)

    private enum ActionCodingKey: String, CodingKey {
        case kind, path, text, cursorOffset, url, name, minutes, label, seconds, steps
        case command, target, source, id, suggestion, mission, template, brief, argument, pid
    }

    private enum ActionKind: String, Codable {
        case launchApplication, copyToClipboard, openURL, openFile, revealInFinder
        case runShortcut, startTimer, wait, runFlow, openWith, quickLook, moveToTrash
        case openSettings, systemCommand, arrangeWindow, remember, confirmCommit, discardCommit
        case runVerb, assignAlias, runMission, missionCancelled, dismiss, cancelAI, openCanvas
        case runAgent, quitProcess, forceQuit, stayAwake, saveWorkspace, restoreWorkspace
        case writeNote, createSnippet, openQuickNoteEditor
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: ActionCodingKey.self)
        let kind = try box.decode(ActionKind.self, forKey: .kind)
        switch kind {
        case .launchApplication: self = .launchApplication(path: try box.decode(String.self, forKey: .path))
        case .copyToClipboard: self = .copyToClipboard(text: try box.decode(String.self, forKey: .text),
                                                        cursorOffset: try box.decodeIfPresent(Int.self, forKey: .cursorOffset))
        case .openURL: self = .openURL(try box.decode(URL.self, forKey: .url))
        case .openFile: self = .openFile(path: try box.decode(String.self, forKey: .path))
        case .revealInFinder: self = .revealInFinder(path: try box.decode(String.self, forKey: .path))
        case .runShortcut: self = .runShortcut(name: try box.decode(String.self, forKey: .name))
        case .startTimer: self = .startTimer(minutes: try box.decode(Int.self, forKey: .minutes), label: try box.decode(String.self, forKey: .label))
        case .wait: self = .wait(seconds: try box.decode(Double.self, forKey: .seconds))
        case .runFlow: self = .runFlow(steps: try box.decode([Action].self, forKey: .steps))
        case .openWith: self = .openWith(path: try box.decode(String.self, forKey: .path))
        case .quickLook: self = .quickLook(path: try box.decode(String.self, forKey: .path))
        case .moveToTrash: self = .moveToTrash(path: try box.decode(String.self, forKey: .path))
        case .openSettings: self = .openSettings
        case .systemCommand: self = .systemCommand(try box.decode(String.self, forKey: .command))
        case .arrangeWindow: self = .arrangeWindow(try box.decode(String.self, forKey: .command))
        case .remember: self = .remember(text: try box.decode(String.self, forKey: .text), source: try box.decode(String.self, forKey: .source))
        case .confirmCommit: self = .confirmCommit(try box.decode(String.self, forKey: .id))
        case .discardCommit: self = .discardCommit(try box.decode(String.self, forKey: .id))
        case .runVerb: self = .runVerb(id: try box.decode(String.self, forKey: .id), text: try box.decode(String.self, forKey: .text))
        case .assignAlias: self = .assignAlias(target: try box.decode(String.self, forKey: .target), suggestion: try box.decode(String.self, forKey: .suggestion))
        case .runMission: self = .runMission(try box.decode(Mission.self, forKey: .mission))
        case .missionCancelled: self = .missionCancelled(try box.decode(Mission.self, forKey: .mission))
        case .dismiss: self = .dismiss
        case .cancelAI: self = .cancelAI
        case .openCanvas: self = .openCanvas(template: try box.decode(String.self, forKey: .template), brief: try box.decode(String.self, forKey: .brief))
        case .runAgent: self = .runAgent(id: try box.decode(String.self, forKey: .id), argument: try box.decode(String.self, forKey: .argument))
        case .quitProcess: self = .quitProcess(pid: try box.decode(String.self, forKey: .pid))
        case .forceQuit: self = .forceQuit(pid: try box.decode(String.self, forKey: .pid))
        case .stayAwake: self = .stayAwake(minutes: try box.decodeIfPresent(Int.self, forKey: .minutes))
        case .saveWorkspace: self = .saveWorkspace(name: try box.decode(String.self, forKey: .name))
        case .restoreWorkspace: self = .restoreWorkspace(name: try box.decode(String.self, forKey: .name))
        case .writeNote: self = .writeNote(text: try box.decode(String.self, forKey: .text))
        case .createSnippet: self = .createSnippet(text: try box.decode(String.self, forKey: .text))
        case .openQuickNoteEditor: self = .openQuickNoteEditor(initialText: try box.decode(String.self, forKey: .text))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: ActionCodingKey.self)
        func kind(_ value: ActionKind) throws { try box.encode(value, forKey: .kind) }
        switch self {
        case .launchApplication(let path): try kind(.launchApplication); try box.encode(path, forKey: .path)
        case .copyToClipboard(let text, let offset): try kind(.copyToClipboard); try box.encode(text, forKey: .text); try box.encodeIfPresent(offset, forKey: .cursorOffset)
        case .openURL(let url): try kind(.openURL); try box.encode(url, forKey: .url)
        case .openFile(let path): try kind(.openFile); try box.encode(path, forKey: .path)
        case .revealInFinder(let path): try kind(.revealInFinder); try box.encode(path, forKey: .path)
        case .runShortcut(let name): try kind(.runShortcut); try box.encode(name, forKey: .name)
        case .startTimer(let minutes, let label): try kind(.startTimer); try box.encode(minutes, forKey: .minutes); try box.encode(label, forKey: .label)
        case .wait(let seconds): try kind(.wait); try box.encode(seconds, forKey: .seconds)
        case .runFlow(let steps): try kind(.runFlow); try box.encode(steps, forKey: .steps)
        case .openWith(let path): try kind(.openWith); try box.encode(path, forKey: .path)
        case .quickLook(let path): try kind(.quickLook); try box.encode(path, forKey: .path)
        case .moveToTrash(let path): try kind(.moveToTrash); try box.encode(path, forKey: .path)
        case .openSettings: try kind(.openSettings)
        case .systemCommand(let command): try kind(.systemCommand); try box.encode(command, forKey: .command)
        case .arrangeWindow(let command): try kind(.arrangeWindow); try box.encode(command, forKey: .command)
        case .remember(let text, let source): try kind(.remember); try box.encode(text, forKey: .text); try box.encode(source, forKey: .source)
        case .confirmCommit(let id): try kind(.confirmCommit); try box.encode(id, forKey: .id)
        case .discardCommit(let id): try kind(.discardCommit); try box.encode(id, forKey: .id)
        case .runVerb(let id, let text): try kind(.runVerb); try box.encode(id, forKey: .id); try box.encode(text, forKey: .text)
        case .assignAlias(let target, let suggestion): try kind(.assignAlias); try box.encode(target, forKey: .target); try box.encode(suggestion, forKey: .suggestion)
        case .runMission(let mission): try kind(.runMission); try box.encode(mission, forKey: .mission)
        case .missionCancelled(let mission): try kind(.missionCancelled); try box.encode(mission, forKey: .mission)
        case .dismiss: try kind(.dismiss)
        case .cancelAI: try kind(.cancelAI)
        case .openCanvas(let template, let brief): try kind(.openCanvas); try box.encode(template, forKey: .template); try box.encode(brief, forKey: .brief)
        case .runAgent(let id, let argument): try kind(.runAgent); try box.encode(id, forKey: .id); try box.encode(argument, forKey: .argument)
        case .quitProcess(let pid): try kind(.quitProcess); try box.encode(pid, forKey: .pid)
        case .forceQuit(let pid): try kind(.forceQuit); try box.encode(pid, forKey: .pid)
        case .stayAwake(let minutes): try kind(.stayAwake); try box.encodeIfPresent(minutes, forKey: .minutes)
        case .saveWorkspace(let name): try kind(.saveWorkspace); try box.encode(name, forKey: .name)
        case .restoreWorkspace(let name): try kind(.restoreWorkspace); try box.encode(name, forKey: .name)
        case .writeNote(let text): try kind(.writeNote); try box.encode(text, forKey: .text)
        case .createSnippet(let text): try kind(.createSnippet); try box.encode(text, forKey: .text)
        case .openQuickNoteEditor(let text): try kind(.openQuickNoteEditor); try box.encode(text, forKey: .text)
        }
    }

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
    public private(set) var textRequest: AIVerb?
    /// The app layer owns the Brain search because it also owns the configured provider and vault.
    /// The launcher only decides that a free-form question should be handed there.
    public var onNaturalLanguageQuestion: (@MainActor (String) -> Void)?

    /// The mission waiting for approval, if any. Shown as a plan the user reads before anything
    /// runs; there is no path that starts a mission without this step.
    public private(set) var mission: Mission?
    private var missionIsRestoredDraft = false
    /// Set by the app layer so a plan survives closing the command window before approval.
    public var onMissionDraftChanged: (@MainActor (Mission?) -> Void)?

    public func restoreMissionDraft(_ draft: Mission) {
        mission = draft
        missionIsRestoredDraft = true
    }

    public func approveMission() {
        guard var current = mission else { return }
        current.state = .running
        mission = current
        onMissionDraftChanged?(nil)
        perform(.runMission(current))
        mission = nil
    }

    public func cancelMission() {
        guard var current = mission else { return }
        current.state = .cancelled
        mission = nil
        onMissionDraftChanged?(nil)
        perform(.missionCancelled(current))
    }

    public func aiWorking(_ title: String) { aiState = .working(title) }
    public func aiAnswered(verb: String, text: String) { aiState = .answer(verb: verb, text: text) }

    /// Appends what has arrived so far. The pane switches from spinner to text on the first
    /// fragment, which is the whole point: 28 seconds of watching a spinner and 28 seconds of
    /// watching an answer being written are not the same experience.
    public func aiStreaming(verb: String, fragment: String) {
        if case .answer(let existing, let text) = aiState, existing == verb {
            aiState = .answer(verb: verb, text: text + fragment)
        } else {
            aiState = .answer(verb: verb, text: fragment)
        }
    }
    public func aiFailed(_ message: String) { aiState = .failed(message) }

    public func requestText(for verb: AIVerb) { textRequest = verb }

    public func submitTextRequest(_ text: String) {
        guard let verb = textRequest,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        textRequest = nil
        perform(.runVerb(id: verb.id, text: text))
    }

    public func cancelTextRequest() { textRequest = nil }
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
            perform(.createSnippet(text: text))
            return true
        case .completeKeyword(let keyword):
            query = keyword
            return true
        case .forceQuit(let pid):
            perform(.forceQuit(pid: pid))
            return true
        case .openActivityMonitor:
            perform(.launchApplication(path: "/System/Applications/Utilities/Activity Monitor.app"))
            return true
        case .openSettings:
            perform(.openSettings)
            return true
        case .moveToTrash(let path):
            perform(.moveToTrash(path: path))
        case .systemCommand(let kind):
            perform(.systemCommand(kind))
        case .writeNote(let text):
            perform(.writeNote(text: text))
            return true
        case .openQuickNoteEditor(let initialText):
            perform(.openQuickNoteEditor(initialText: initialText))
            return true
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

    /// The brain, when one has been built. Set after construction because finding an embedding
    /// model is a network call and the window has to be able to open before it finishes.
    public var brain: BrainSearch?

    /// Rows the brain returned, and the query they answer.
    ///
    /// Held separately from `results` because they arrive after the list has already been drawn.
    /// Merging them into the same array on arrival — rather than redrawing from scratch — is what
    /// keeps the selection where the person left it while they were reading.
    private var recallRows: [SearchResult] = []
    private var recallQuery = ""
    private var recallTask: Task<Void, Never>?

    /// Long enough that typing a word does not fire a request per keystroke, short enough that it
    /// lands while the person is still looking at the list.
    public static let recallDelay: Duration = .milliseconds(220)

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
        if missionIsRestoredDraft {
            missionIsRestoredDraft = false
        } else {
            onMissionDraftChanged?(nil)
            mission = nil
        }
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
                if mode == .clipboard {
                    results = SearchEngine.recents(input.clips)
                } else {
                    results = SearchEngine.brainLaunchpadResults() + SearchEngine.recents(input.clips)
                }
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
                mergeRecall(for: trimmed)
                scheduleRecall(for: trimmed)
            }
        } catch {
            results = []
            state = .failed("\(error)")
        }
        selection = min(selection, max(results.count - 1, 0))
        if isActionPanelOpen, results.isEmpty { closeActionPanel() }
    }

    // MARK: - Recall

    /// Adds whatever the brain has already answered for this exact query.
    ///
    /// Only for this query: showing the previous question's memories under a new one is how a
    /// search box starts feeling haunted.
    private func mergeRecall(for query: String) {
        guard recallQuery == query, !recallRows.isEmpty else { return }
        let known = Set(results.map(\.id))
        results += recallRows.filter { !known.contains($0.id) }
        if state == .noMatch, !results.isEmpty { state = .results }
    }

    private func scheduleRecall(for query: String) {
        guard let brain, query.count >= 4, recallQuery != query else { return }
        recallTask?.cancel()
        recallTask = Task { [weak self] in
            try? await Task.sleep(for: LauncherModel.recallDelay)
            guard !Task.isCancelled else { return }
            let result = await brain.search(query, limit: 5)
            guard !Task.isCancelled else { return }
            guard let self, self.query.trimmingCharacters(in: .whitespaces) == query else { return }
            self.recallQuery = query
            self.recallRows = RecallResults.rows(from: result)
            // Through the normal path rather than by appending to `results` from here.
            //
            // Mutating the list from outside `refresh()` meant rows appeared without the rest of
            // the state being recomputed: the selection index, the empty/loading state and the
            // action panel were all left describing the list as it was a moment earlier, and the
            // window resized around a layout that had not been rebuilt. One code path produces
            // the list, always.
            self.refresh()
        }
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
        if result.id.hasPrefix("brain-"), let completion = result.completion {
            query = completion
            return true
        }
        switch result.kind {
        case .recall:
            perform(.copyToClipboard(text: result.payload, cursorOffset: nil))
            perform(.dismiss)

        case .application:
            onLaunch(result.payload)
            perform(.launchApplication(path: result.payload))
            perform(.dismiss)

        case .system:
            // The stay-awake rows are system rows carrying a duration rather than a command.
            if result.payload.hasPrefix("awake:") {
                let rest = String(result.payload.dropFirst("awake:".count))
                perform(.stayAwake(minutes: rest.isEmpty ? nil : Int(rest)))
                return true
            }
            perform(.systemCommand(result.payload))
            perform(.dismiss)

        case .shortcut:
            perform(.runShortcut(name: result.payload))
            perform(.dismiss)

        case .memory:
            perform(.copyToClipboard(text: result.title, cursorOffset: nil))
            perform(.dismiss)

        case .process:
            // Enter quits politely: it lets the app save. Forcing lives behind ⌘K on purpose.
            perform(.quitProcess(pid: result.payload))
            return true

        case .agent:
            // "<pack id>\u{1F}<argument>". A trailing separator with nothing after it means the
            // person picked from the slash menu and still has to type the argument.
            guard let split = result.payload.firstIndex(of: "\u{1F}") else { return false }
            let argument = String(result.payload[result.payload.index(after: split)...])
            if argument.isEmpty, let completion = result.completion {
                query = completion
                return true
            }
            perform(.runAgent(id: String(result.payload[..<split]), argument: argument))
            return true

        case .mission:
            guard let planned = MissionPlanner.plan(result.payload) else { return false }
            mission = planned
            onMissionDraftChanged?(planned)
            return true

        case .answer:
            if result.id == "reminder-create" {
                perform(.systemCommand("bel:reminders.create\u{1F}\(result.payload)"))
                return true
            }
            if result.id == "contact-create" {
                perform(.systemCommand("bel:contacts.create\u{1F}\(result.payload)"))
                return true
            }
            if result.id.hasPrefix("source-permission-") {
                perform(.openSettings)
                return true
            }
            if result.id == "brain-question" {
                onNaturalLanguageQuestion?(result.payload)
                return true
            }
            if result.id.hasPrefix("verb-input-"),
               let verb = AIVerb.named(String(result.id.dropFirst("verb-input-".count))) {
                requestText(for: verb)
                return true
            }
            if result.payload.isEmpty, let completion = result.completion {
                query = completion
                return true
            }
            if result.id == "brain-note" {
                perform(.openQuickNoteEditor(initialText: ""))
                return true
            }
            if result.id == "note" {
                perform(.writeNote(text: result.payload))
                return true
            }
            if result.id == "new-note" {
                perform(.openQuickNoteEditor(initialText: result.payload))
                return true
            }
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

        case .window where result.payload.hasPrefix("save:"):
            perform(.saveWorkspace(name: String(result.payload.dropFirst(5))))
            return true

        case .window where result.payload.hasPrefix("restore:"):
            perform(.restoreWorkspace(name: String(result.payload.dropFirst(8))))
            return true

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

        case .reminder:
            perform(.copyToClipboard(text: result.title, cursorOffset: nil))
            perform(.dismiss)

        case .contact:
            perform(.copyToClipboard(text: result.subtitle, cursorOffset: nil))
            perform(.dismiss)

        case .photo:
            perform(.systemCommand("bel:photos.open\u{1F}\(result.payload)"))

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
