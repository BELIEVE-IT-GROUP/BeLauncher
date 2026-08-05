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
    }

    public enum Action: Equatable, Sendable {
        case launchApplication(path: String)
        case copyToClipboard(text: String, cursorOffset: Int?)
        case openURL(URL)
        case dismiss
    }

    public private(set) var state: State = .loading
    public private(set) var results: [SearchResult] = []
    public private(set) var selection: Int = 0
    /// Bumped every time the window is shown so the text field can re-take focus.
    public private(set) var focusToken: Int = 0

    public var query: String = "" {
        didSet { if query != oldValue { refresh() } }
    }

    public var isIndexing: Bool = false {
        didSet { if isIndexing != oldValue { refresh() } }
    }

    private let dataSource: @MainActor () throws -> SearchInput
    private let expanderFactory: @MainActor () -> SnippetExpander
    private let perform: @MainActor (Action) -> Void
    private let recordUse: @MainActor (ResultKind, Int64) -> Void

    public init(
        dataSource: @escaping @MainActor () throws -> SearchInput,
        expander: @escaping @MainActor () -> SnippetExpander = { SnippetExpander() },
        recordUse: @escaping @MainActor (ResultKind, Int64) -> Void = { _, _ in },
        perform: @escaping @MainActor (Action) -> Void
    ) {
        self.dataSource = dataSource
        self.expanderFactory = expander
        self.recordUse = recordUse
        self.perform = perform
    }

    // MARK: - Lifecycle

    /// Called every time the window is summoned.
    public func activate() {
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
            } else {
                results = SearchEngine.search(query, in: input)
                state = results.isEmpty ? .noMatch : .results
            }
        } catch {
            results = []
            state = .failed("\(error)")
        }
        selection = min(selection, max(results.count - 1, 0))
    }

    // MARK: - Keyboard

    /// Returns true when the key was consumed.
    @discardableResult
    public func handle(_ key: Key) -> Bool {
        switch key {
        case .escape:
            perform(.dismiss)
            return true
        case .down:
            guard !results.isEmpty else { return true }
            selection = (selection + 1) % results.count
            return true
        case .up:
            guard !results.isEmpty else { return true }
            selection = (selection - 1 + results.count) % results.count
            return true
        case .tab:
            // Autocomplete a workflow keyword so the user can type its argument.
            guard let completion = selected?.completion else { return false }
            query = completion
            return true
        case .enter:
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
            recordUse(.application, result.recordID)
            perform(.launchApplication(path: result.payload))
            perform(.dismiss)

        case .clipboard:
            perform(.copyToClipboard(text: result.payload, cursorOffset: nil))
            perform(.dismiss)

        case .snippet:
            let expanded = expanderFactory().expand(result.payload, query: query)
            recordUse(.snippet, result.recordID)
            perform(.copyToClipboard(text: expanded.text, cursorOffset: expanded.cursorOffset))
            perform(.dismiss)

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
