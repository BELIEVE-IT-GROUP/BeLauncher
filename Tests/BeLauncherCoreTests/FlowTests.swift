import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Flows")
struct FlowTests {

    /// The flow from the landing page, verbatim.
    private let focus = Flow(
        id: 1, keyword: "enfoque", title: "Modo enfoque",
        steps: [
            .runShortcut(name: "Silenciar notificaciones"),
            .openApp(path: "/Applications/Notion.app"),
            .openApp(path: "/System/Applications/Utilities/Terminal.app"),
            .timer(minutes: 50, label: "Bloque de enfoque"),
        ]
    )

    @Test("a flow plans its steps in order and closes the window at the end")
    func plansInOrder() {
        #expect(FlowRunner.plan(focus) == [
            .runShortcut(name: "Silenciar notificaciones"),
            .launchApplication(path: "/Applications/Notion.app"),
            .launchApplication(path: "/System/Applications/Utilities/Terminal.app"),
            .startTimer(minutes: 50, label: "Bloque de enfoque"),
            .dismiss,
        ])
    }

    @Test("every step kind is planned")
    func everyStepKind() {
        let flow = Flow(keyword: "todo", title: "Todo", steps: [
            .openURL(url: "https://example.com"),
            .openFile(path: "/tmp/notes.md"),
            .copyText(text: "hola"),
            .wait(seconds: 2),
        ])
        #expect(FlowRunner.plan(flow) == [
            .openURL(URL(string: "https://example.com")!),
            .openFile(path: "/tmp/notes.md"),
            .copyToClipboard(text: "hola", cursorOffset: nil),
            .wait(seconds: 2),
            .dismiss,
        ])
    }

    @Test("a snippet step is expanded when it runs, not when it is saved")
    func expandsSnippets() {
        let flow = Flow(keyword: "saludo", title: "Saludo", steps: [.runSnippet(keyword: "sig")])
        let snippets = [Snippet(id: 1, keyword: "sig", title: "Firma", body: "Hola {cursor}Jorge")]
        let plan = FlowRunner.plan(
            flow, snippets: snippets,
            expander: SnippetExpander(uuid: { "X" }, now: Date(timeIntervalSince1970: 0))
        )
        #expect(plan == [.copyToClipboard(text: "Hola Jorge", cursorOffset: 5), .dismiss])
    }

    @Test("a step pointing at a missing snippet is skipped, the rest of the flow still runs")
    func skipsMissingSnippet() {
        let flow = Flow(keyword: "x", title: "X", steps: [
            .runSnippet(keyword: "nope"),
            .openApp(path: "/Applications/Safari.app"),
        ])
        #expect(FlowRunner.plan(flow) == [.launchApplication(path: "/Applications/Safari.app"), .dismiss])
    }

    @Test("validation refuses empty flows, bad URLs, bad timers and unusable shortcut names")
    func validation() {
        #expect(throws: FlowError.noSteps) { try FlowValidator.validate([]) }
        #expect(throws: FlowError.badURL("file:///etc/passwd")) {
            try FlowValidator.validate([.openURL(url: "file:///etc/passwd")])
        }
        #expect(throws: FlowError.badTimer(0)) {
            try FlowValidator.validate([.timer(minutes: 0, label: "")])
        }
        #expect(throws: FlowError.badTimer(5000)) {
            try FlowValidator.validate([.timer(minutes: 5000, label: "")])
        }
        #expect(throws: FlowError.badShortcutName("bad\nname")) {
            try FlowValidator.validate([.runShortcut(name: "bad\nname")])
        }
        #expect(throws: FlowError.unknownSnippet("ghost")) {
            try FlowValidator.validate([.runSnippet(keyword: "ghost")], snippetKeywords: ["sig"])
        }
    }

    @Test("valid flows pass")
    func acceptsValid() throws {
        try FlowValidator.validate(focus.steps)
    }

    @Test("flows survive a round trip through the database")
    @MainActor
    func persistence() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-flow-\(UUID().uuidString)")
            .appendingPathComponent("s.sqlite3").path
        let store = try Store(path: path)

        try store.addFlow(keyword: "Enfoque", title: "Modo enfoque", steps: focus.steps)
        let loaded = try #require(store.flows().first)
        #expect(loaded.keyword == "enfoque")
        #expect(loaded.steps == focus.steps)

        #expect(throws: ValidationError.duplicateKeyword("enfoque")) {
            try store.addFlow(keyword: "enfoque", title: "Otro", steps: [.wait(seconds: 1)])
        }

        try store.updateFlowSteps(id: loaded.id, steps: [.timer(minutes: 25, label: "Pomodoro")])
        #expect(store.flows().first?.steps == [.timer(minutes: 25, label: "Pomodoro")])

        store.deleteFlow(id: loaded.id)
        #expect(store.flows().isEmpty)
    }

    @Test("a flow is searchable by keyword and Enter runs the whole chain")
    @MainActor
    func endToEnd() {
        var performed: [LauncherModel.Action] = []
        let input = SearchInput(
            applications: [Application(name: "Notion", path: "/Applications/Notion.app")],
            flows: [focus]
        )
        let model = LauncherModel(dataSource: { input }, perform: { performed.append($0) })
        model.activate()
        model.query = "enfoque"

        #expect(model.selected?.kind == .flow)
        #expect(model.selected?.subtitle == "enfoque · 4 steps")

        model.handle(.enter)
        guard case .runFlow(let steps) = performed.first else {
            Issue.record("expected a runFlow action")
            return
        }
        #expect(steps.count == 5)
        #expect(steps.first == .runShortcut(name: "Silenciar notificaciones"))
        #expect(steps.last == .dismiss)
    }
}
