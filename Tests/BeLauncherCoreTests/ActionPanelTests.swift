import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Actions and preview")
@MainActor
struct ActionPanelTests {

    private let input = SearchInput(
        applications: [Application(name: "Safari", path: "/Applications/Safari.app")],
        snippets: [Snippet(id: 7, keyword: "sig", title: "Firma", body: "Hola {cursor}Jorge", uses: 3)],
        workflows: [Workflow(id: 3, keyword: "gh", title: "GitHub",
                             urlTemplate: "https://github.com/search?q={query}")],
        clips: [Clip(id: 9, text: "texto copiado", sourceApp: "Xcode",
                     createdAt: Date(timeIntervalSince1970: 1_700_000_000))],
        flows: [Flow(id: 4, keyword: "focus", title: "Enfoque",
                     steps: [.openApp(path: "/Applications/Notion.app"), .timer(minutes: 50, label: "Bloque")])]
    )

    private func model(_ record: @escaping @MainActor (LauncherModel.Action) -> Void = { _ in },
                       onDelete: @escaping @MainActor (ResultKind, Int64) -> Void = { _, _ in })
    -> LauncherModel {
        LauncherModel(
            dataSource: { input },
            onDelete: onDelete,
            expander: { SnippetExpander(uuid: { "U" }, now: Date(timeIntervalSince1970: 0)) },
            perform: record
        )
    }

    // MARK: - Registry

    @Test("every kind offers a primary action bound to Return")
    func primaryEverywhere() {
        for kind in ResultKind.allCases {
            let result = SearchResult(id: "x", kind: kind, title: "t", subtitle: "s",
                                      score: 1, matched: [], payload: "/tmp/x", recordID: 1)
            let actions = ActionRegistry.actions(for: result)
            #expect(!actions.isEmpty, "\(kind) has no actions")
            #expect(actions.first?.shortcut?.display == "↩", "\(kind) has no Return action")
        }
    }

    @Test("Command-Return maps to the second action, the platform convention")
    func secondaryIsSecond() {
        let app = SearchResult(id: "a", kind: .application, title: "Safari", subtitle: "",
                               score: 1, matched: [], payload: "/Applications/Safari.app")
        let secondary = ActionRegistry.secondary(for: app)
        #expect(secondary?.id == "reveal")
        #expect(secondary?.shortcut?.display == "⌘↩")
    }

    @Test("destructive actions are flagged and grouped apart")
    func destructiveIsMarked() {
        let clip = SearchResult(id: "c", kind: .clipboard, title: "t", subtitle: "",
                                score: 1, matched: [], payload: "t", recordID: 9)
        let delete = ActionRegistry.actions(for: clip).first { $0.id == "delete" }
        #expect(delete?.isDestructive == true)
        #expect(delete?.section == .danger)
    }

    @Test("the panel filters by fuzzy title, like the main list")
    func filtering() {
        let file = SearchResult(id: "f", kind: .file, title: "notas.md", subtitle: "",
                                score: 1, matched: [], payload: "/tmp/notas.md")
        let actions = ActionRegistry.actions(for: file)
        #expect(ActionRegistry.filter(actions, query: "").count == actions.count)
        #expect(ActionRegistry.filter(actions, query: "trash").first?.id == "trash")
        #expect(ActionRegistry.filter(actions, query: "zzzz").isEmpty)
    }

    // MARK: - Panel behaviour

    @Test("Command-K opens the panel, Escape closes it before closing the window")
    func panelOpensAndCloses() {
        var actions: [LauncherModel.Action] = []
        let model = model { actions.append($0) }
        model.activate()
        model.query = "safari"

        model.handle(.actionPanel)
        #expect(model.isActionPanelOpen)
        #expect(model.visibleActions.count == ActionRegistry.actions(for: model.selected!).count)

        model.handle(.escape)
        #expect(!model.isActionPanelOpen)
        #expect(actions.isEmpty, "escape closed the panel, it must not dismiss the window too")

        model.handle(.escape)
        #expect(actions == [.dismiss])
    }

    @Test("arrows move inside the panel, not through the results")
    func arrowsStayInThePanel() {
        let model = model()
        model.activate()
        model.query = "safari"
        let resultSelection = model.selection

        model.handle(.actionPanel)
        model.handle(.down)
        #expect(model.actionSelection == 1)
        #expect(model.selection == resultSelection)

        model.handle(.up)
        #expect(model.actionSelection == 0)
    }

    @Test("Return inside the panel runs the highlighted action")
    func returnRunsHighlighted() {
        var performed: [LauncherModel.Action] = []
        let model = model { performed.append($0) }
        model.activate()
        model.query = "safari"

        model.handle(.actionPanel)
        model.handle(.down)                       // "Mostrar en Finder"
        model.handle(.enter)

        #expect(performed.contains(.revealInFinder(path: "/Applications/Safari.app")))
        #expect(!model.isActionPanelOpen)
    }

    @Test("Command-Return runs the secondary action without opening the panel")
    func secondaryShortcut() {
        var performed: [LauncherModel.Action] = []
        let model = model { performed.append($0) }
        model.activate()
        model.query = "safari"
        model.handle(.secondaryAction)
        #expect(performed.first == .revealInFinder(path: "/Applications/Safari.app"))
    }

    @Test("deleting from the panel goes through the store and refreshes")
    func deleteRoutes() {
        var deleted: [(ResultKind, Int64)] = []
        let model = model(onDelete: { kind, id in deleted.append((kind, id)) })
        model.activate()
        model.query = "texto copiado"

        let delete = try! #require(model.actions.first { $0.id == "delete" })
        model.run(delete)
        #expect(deleted.count == 1)
        #expect(deleted.first?.0 == .clipboard)
        #expect(deleted.first?.1 == 9)
    }

    @Test("a shortcut only fires with its exact modifiers")
    func shortcutMatching() {
        let copyPath = ResultAction.Shortcut.copyPath      // ⇧⌘C
        #expect(copyPath.matches(characters: "c", keyCode: 8, command: true, shift: true, option: false))
        #expect(!copyPath.matches(characters: "c", keyCode: 8, command: true, shift: false, option: false))
        #expect(!copyPath.matches(characters: "v", keyCode: 9, command: true, shift: true, option: false))

        #expect(ResultAction.Shortcut.commandEnter
            .matches(characters: "", keyCode: 36, command: true, shift: false, option: false))
        #expect(!ResultAction.Shortcut.enter
            .matches(characters: "", keyCode: 36, command: true, shift: false, option: false))
    }

    // MARK: - Preview

    @Test("the preview shows the snippet already expanded, plus its metadata")
    func snippetPreview() {
        let model = model()
        model.activate()
        model.query = "sig"
        let detail = try! #require(model.detail)
        #expect(detail.body == "Hola Jorge")
        #expect(detail.metadata.contains { $0.label == "Keyword" && $0.value == "sig" })
        #expect(detail.metadata.contains { $0.label == "Used" && $0.value == "3" })
    }

    @Test("a flow previews its steps in order")
    func flowPreview() {
        let model = model()
        model.activate()
        model.query = "focus"
        let detail = try! #require(model.detail)
        #expect(detail.body.contains("1. Open Notion"))
        #expect(detail.body.contains("2. Timer 50 min · Bloque"))
    }

    @Test("a clip preview says where it came from and uses monospace for data")
    func clipPreview() {
        let model = model()
        model.activate()
        model.query = "texto copiado"
        let detail = try! #require(model.detail)
        #expect(detail.metadata.contains { $0.label == "From" && $0.value == "Xcode" })
        #expect(!detail.isMonospaced)

        #expect(DetailBuilder.looksLikeData("{\"a\":1}"))
        #expect(DetailBuilder.looksLikeData("https://example.com"))
        #expect(!DetailBuilder.looksLikeData("una nota normal"))
    }

    @Test("opening the panel with nothing selected does nothing")
    func noSelectionNoPanel() {
        let model = model()
        model.activate()
        model.query = "zzzzqqqq"
        model.handle(.actionPanel)
        #expect(!model.isActionPanelOpen)
        #expect(model.actions.isEmpty)
    }
}
