import Testing
import Foundation
@testable import BeLauncherCore

/// End-to-end keyboard workflow.
///
/// The command window is a thin SwiftUI shell over `LauncherModel`: the panel's key monitor
/// forwards ⌥Space/↑/↓/⇥/↩/esc to `handle(_:)` and nothing else. Driving that same entry point
/// exercises the whole user-visible loop — typing, filtering, selecting, running — without
/// XCUITest, which SwiftPM cannot host for a menu-bar-only executable.
@Suite("Keyboard workflow (end to end)")
@MainActor
struct KeyboardWorkflowTests {

    final class Recorder {
        var actions: [LauncherModel.Action] = []
        var uses: [(ResultKind, Int64)] = []
    }

    private func makeModel(
        clips: [Clip] = [],
        files: [FoundFile] = [],
        recorder: Recorder
    ) -> LauncherModel {
        let input = SearchInput(
            applications: [
                Application(name: "Safari", path: "/Applications/Safari.app"),
                Application(name: "System Settings", path: "/System/Applications/System Settings.app"),
            ],
            snippets: [Snippet(id: 7, keyword: "sig", title: "Signature", body: "Best,\n{cursor}Jorge")],
            workflows: [Workflow(id: 3, keyword: "gh", title: "Search GitHub",
                                 urlTemplate: "https://github.com/search?q={query}")],
            clips: clips
        )
        return LauncherModel(
            dataSource: { input },
            fileSearch: FileSearch { _, limit in Array(files.prefix(limit)) },
            expander: {
                SnippetExpander(clipboard: { nil }, secret: { _ in nil }, uuid: { "UUID" },
                                now: Date(timeIntervalSince1970: 0))
            },
            recordUse: { kind, id in recorder.uses.append((kind, id)) },
            perform: { recorder.actions.append($0) }
        )
    }

    @Test("happy path: summon, type, arrow down, Enter launches the app and closes the window")
    func launchAnApplication() {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder)

        // 1. The hotkey summons the window.
        model.activate()
        #expect(model.state == .empty)
        #expect(model.focusToken == 1)

        // 2. The user types.
        model.query = "sa"
        #expect(model.state == .results)
        #expect(model.selected?.title == "Safari")

        // 3. Arrow keys move the selection and wrap around.
        let count = model.results.count
        model.handle(.down)
        #expect(model.selection == (1 % count))
        model.handle(.up)
        #expect(model.selection == 0)

        // 4. Enter runs the selection and dismisses.
        model.handle(.enter)
        #expect(recorder.actions == [
            .launchApplication(path: "/Applications/Safari.app"),
            .dismiss,
        ])
    }

    @Test("Escape closes the window without running anything")
    func escapeDismisses() {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder)
        model.activate()
        model.query = "safari"
        model.handle(.escape)
        #expect(recorder.actions == [.dismiss])
    }

    @Test("snippets are expanded at the moment they are run")
    func runSnippet() {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder)
        model.activate()
        model.query = "sig"
        #expect(model.selected?.kind == .snippet)

        model.handle(.enter)
        #expect(recorder.actions.first == .copyToClipboard(text: "Best,\nJorge", cursorOffset: 6))
        #expect(recorder.uses.first?.0 == .snippet)
        #expect(recorder.uses.first?.1 == 7)
    }

    @Test("workflow keyword completes with Tab, then Enter opens the built URL")
    func runWorkflow() {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder)
        model.activate()

        model.query = "gh"
        #expect(model.selected?.kind == .workflow)

        // Enter with no argument primes the query instead of opening a broken URL.
        model.handle(.enter)
        #expect(model.query == "gh ")
        #expect(recorder.actions.isEmpty)

        model.query = "gh swift 6"
        #expect(model.results.count == 1)
        model.handle(.enter)
        #expect(recorder.actions == [
            .openURL(URL(string: "https://github.com/search?q=swift%206")!),
            .dismiss,
        ])
    }

    @Test("empty query shows recent clipboard items, and Enter copies one back")
    func recentClipboard() {
        let recorder = Recorder()
        let model = makeModel(clips: [Clip(id: 1, text: "copied earlier", sourceApp: "Xcode")], recorder: recorder)
        model.activate()

        #expect(model.state == .empty)
        #expect(model.results.map(\.title) == ["copied earlier"])
        model.handle(.enter)
        #expect(recorder.actions == [.copyToClipboard(text: "copied earlier", cursorOffset: nil), .dismiss])
    }

    @Test("states cover loading, no match and a recoverable failure")
    func states() {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder)

        model.isIndexing = true
        #expect(model.state == .loading)
        #expect(model.results.isEmpty)

        model.isIndexing = false
        model.query = "zzzzqqqq"
        #expect(model.state == .noMatch)

        struct Boom: Error {}
        var shouldFail = true
        let failing = LauncherModel(
            dataSource: { if shouldFail { throw Boom() } else { return SearchInput() } },
            perform: { recorder.actions.append($0) }
        )
        failing.refresh()
        guard case .failed = failing.state else {
            Issue.record("expected a failed state")
            return
        }
        // Recoverable: the user hits Retry and the window comes back to life.
        shouldFail = false
        failing.retry()
        #expect(failing.state == .empty)
    }

    @Test("a calculation is pinned above everything and Enter copies the raw value")
    func calculation() {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder)
        model.activate()
        model.query = "15% of 300"

        #expect(model.selected?.kind == .calculation)
        #expect(model.selected?.title == "45")
        model.handle(.enter)
        #expect(recorder.actions == [.copyToClipboard(text: "45", cursorOffset: nil), .dismiss])
    }

    @Test("the f prefix lists files, Enter opens and Command-Enter reveals")
    func fileSearch() {
        let recorder = Recorder()
        let model = makeModel(
            files: [FoundFile(name: "budget.numbers", path: "/Users/x/Docs/budget.numbers")],
            recorder: recorder
        )
        model.activate()
        model.query = "f budget"

        #expect(model.results.map(\.kind) == [.file])
        #expect(model.selected?.title == "budget.numbers")

        model.handle(.revealInFinder)
        #expect(recorder.actions == [.revealInFinder(path: "/Users/x/Docs/budget.numbers"), .dismiss])

        recorder.actions.removeAll()
        model.handle(.enter)
        #expect(recorder.actions == [.openFile(path: "/Users/x/Docs/budget.numbers"), .dismiss])
    }

    @Test("Command-Enter reveals an app and does nothing for a snippet")
    func revealScope() {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder)
        model.activate()
        model.query = "safari"
        #expect(model.handle(.revealInFinder) == true)
        #expect(recorder.actions.first == .revealInFinder(path: "/Applications/Safari.app"))

        recorder.actions.removeAll()
        model.query = "sig"
        #expect(model.selected?.kind == .snippet)
        #expect(model.handle(.revealInFinder) == false)
        #expect(recorder.actions.isEmpty)
    }

    @Test("clipboard mode only ever shows clipboard entries")
    func clipboardMode() {
        let recorder = Recorder()
        let model = makeModel(
            clips: [Clip(id: 1, text: "safari bookmark", sourceApp: "Safari")],
            recorder: recorder
        )
        model.activate(mode: .clipboard)
        #expect(model.mode == .clipboard)

        // "safari" would match the Safari app in normal mode; here it must not.
        model.query = "safari"
        #expect(model.results.map(\.kind) == [.clipboard])
        #expect(model.selected?.title == "safari bookmark")
    }

    @Test("keys do nothing harmful when there is nothing to select")
    func emptyResultsAreSafe() {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder)
        model.activate()
        model.query = "zzzzqqqq"
        model.handle(.down)
        model.handle(.up)
        #expect(model.handle(.enter) == false)
        #expect(recorder.actions.isEmpty)
    }
}
