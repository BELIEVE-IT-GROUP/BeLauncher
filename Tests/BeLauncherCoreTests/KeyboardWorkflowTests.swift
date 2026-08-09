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

    @Test("the visible snippets route lists saved snippets before running one")
    func browseSnippets() {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder)
        model.activate()
        model.query = "/snippet"
        #expect(model.results.count == 1)
        #expect(model.selected?.kind == .snippet)
        #expect(model.selected?.title == "Signature")

        model.handle(.enter)
        #expect(recorder.actions.first == .copyToClipboard(text: "Best,\nJorge", cursorOffset: 6))
    }

    @Test("shortcuts can be browsed without knowing their exact name")
    func browseShortcuts() {
        let results = SearchEngine.search("/shortcuts",
                                          in: SearchInput(systemShortcuts: ["Focus block"]))
        #expect(results.count == 1)
        #expect(results.first?.kind == .shortcut)
        #expect(results.first?.payload == "Focus block")
    }

    @Test("reminders can be browsed and searched from the launcher")
    func browseReminders() {
        let reminder = ReminderItem(id: "r1", title: "Enviar propuesta", list: "Trabajo")
        let input = SearchInput(reminders: [reminder], remindersAuthorised: true)
        let listed = SearchEngine.search("/reminders", in: input)
        #expect(listed.count == 1)
        #expect(listed.first?.kind == .reminder)
        #expect(listed.first?.payload == "r1")

        let found = SearchEngine.search("propuesta", in: input)
        #expect(found.first?.id == "reminder-r1")
        #expect(ActionRegistry.actions(for: found[0]).contains {
            $0.intent == .systemCommand("bel:reminders.open\u{1F}r1")
        })
    }

    @Test("a reminder list command is explicit and does not become a create command")
    func browseReminderList() {
        let results = SearchEngine.search("/reminders list Trabajo",
                                          in: SearchInput(remindersAuthorised: true))
        #expect(results.count == 1)
        #expect(results.first?.id == "reminder-list")
        #expect(results.first?.payload == "Trabajo")
        #expect(ActionRegistry.actions(for: results[0]).first?.intent
                == .systemCommand("bel:reminders.show_list\u{1F}Trabajo"))
    }

    @Test("completed reminders are opt-in and offer undo instead of completion")
    func browseCompletedReminders() throws {
        let completed = ReminderItem(id: "done-1", title: "Enviar factura", list: "Trabajo")
        let results = SearchEngine.search("/reminders completed",
                                          in: SearchInput(completedReminders: [completed],
                                                          remindersAuthorised: true))
        let result = try #require(results.first)
        #expect(result.id == "completed-reminder-done-1")
        #expect(ActionRegistry.actions(for: result).map(\.title).contains("Undo completion"))
        #expect(ActionRegistry.actions(for: result).last?.intent
                == .systemCommand("bel:reminders.uncomplete\u{1F}done-1"))
    }

    @Test("creating a reminder list is explicit and carries the full name")
    func createReminderListCommand() throws {
        let result = try #require(SearchEngine.search("/reminders new list Proyectos 2026",
                                                       in: SearchInput(remindersAuthorised: true)).first)
        #expect(result.id == "reminder-list-create")
        #expect(result.payload == "Proyectos 2026")
        #expect(ActionRegistry.actions(for: result).first?.intent
                == .systemCommand("bel:reminders.create_list\u{1F}Proyectos 2026"))
    }

    @Test("an explicit reminder command creates a confirmed action")
    func createReminderCommand() {
        let input = SearchInput(remindersAuthorised: true)
        let result = SearchEngine.search("/reminder llamar al cliente", in: input).first
        #expect(result?.id == "reminder-create")
        #expect(result?.payload == "llamar al cliente")
        #expect(ActionRegistry.actions(for: result!).first?.title == "Create reminder")
        #expect(ActionRegistry.actions(for: result!).first?.isDestructive == false)
    }

    @Test("contact creation is explicit and permission-aware")
    func createContactCommand() throws {
        let input = SearchInput(contactsAuthorised: true)
        let result = try #require(SearchEngine.search("/contact add Ada Lovelace", in: input).first)
        #expect(result.id == "contact-create")
        #expect(result.payload == "Ada Lovelace")
        #expect(ActionRegistry.actions(for: result).first?.intent
                == .systemCommand("bel:contacts.create\u{1F}Ada Lovelace"))
    }

    @Test("a contact result opens its exact record, not an empty Contacts window")
    func openContactAction() throws {
        let contact = ContactItem(id: "contact-42", name: "Ada Lovelace",
                                  email: "ada@example.com", phone: "")
        let result = try #require(SearchEngine.search("Ada", in: SearchInput(contacts: [contact])).first)
        #expect(ActionRegistry.actions(for: result).contains {
            $0.intent == .systemCommand("bel:contacts.open\u{1F}contact-42")
        })
    }

    @Test("an unavailable local source explains how to unlock it")
    func sourcePermissionResultIsActionable() {
        let result = SearchEngine.search("/contacts", in: SearchInput()).first
        #expect(result?.id == "source-permission-contacts")
        #expect(ActionRegistry.actions(for: result!).first?.intent == .openSettings)
    }

    @Test("an unmatched natural-language question is handed to the Brain")
    func naturalLanguageQuestion() {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder)
        var handedOff = ""
        model.onNaturalLanguageQuestion = { handedOff = $0 }
        model.activate()
        model.query = "what is the status of Project Atlas"
        #expect(model.selected?.id == "brain-question")

        model.handle(.enter)
        #expect(handedOff == "what is the status of Project Atlas")
    }

    @Test("everyday AI verbs use the last copied text without opening a hidden menu")
    func naturalLanguageVerb() {
        let recorder = Recorder()
        let model = makeModel(
            clips: [Clip(id: 21, text: "A long note that needs a useful summary.", sourceApp: "Notes")],
            recorder: recorder)
        model.activate()
        model.query = "resume esto"
        #expect(model.selected?.id == "verb-summarise")
        #expect(model.results.filter { $0.id == "verb-summarise" }.count == 1)
        model.handle(.enter)
        #expect(recorder.actions == [
            .runVerb(id: "summarise", text: "A long note that needs a useful summary.")
        ])
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

    @Test("empty query keeps brain actions and recent clipboard items")
    func recentClipboard() {
        let recorder = Recorder()
        let model = makeModel(clips: [Clip(id: 1, text: "copied earlier", sourceApp: "Xcode")], recorder: recorder)
        model.activate()

        #expect(model.state == .empty)
        #expect(model.results.first?.id == "brain-open")
        let clipIndex = try! #require(model.results.firstIndex { $0.title == "copied earlier" })
        model.select(clipIndex)
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

        model.handle(.secondaryAction)
        #expect(recorder.actions == [.revealInFinder(path: "/Users/x/Docs/budget.numbers"), .dismiss])

        recorder.actions.removeAll()
        model.handle(.enter)
        #expect(recorder.actions == [.openFile(path: "/Users/x/Docs/budget.numbers"), .dismiss])
    }

    @Test("Command-Enter reveals an app, and on a snippet runs its own second action")
    func revealScope() {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder)
        model.activate()
        model.query = "safari"
        #expect(model.handle(.secondaryAction) == true)
        #expect(recorder.actions.first == .revealInFinder(path: "/Applications/Safari.app"))

        recorder.actions.removeAll()
        model.query = "sig"
        #expect(model.selected?.kind == .snippet)
        // A snippet's second action opens Settings to edit it — never a reveal.
        model.handle(.secondaryAction)
        #expect(recorder.actions == [.openSettings])
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
