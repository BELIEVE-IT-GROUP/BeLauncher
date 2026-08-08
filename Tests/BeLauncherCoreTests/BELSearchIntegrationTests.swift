import Testing
@testable import BeLauncherCore

@Suite("BEL search integration")
struct BELSearchIntegrationTests {
    @Test("native action resolves into an executable result")
    func nativeAction() {
        let result = SearchEngine.search("lock", in: SearchInput()).first

        #expect(result?.actionID == "system.lock_screen")
        #expect(result?.kind == .system)
        #expect(result?.payload == SystemCommand.Kind.lockScreen.rawValue)
    }

    @Test("AI action keeps the copied text in the legacy execution payload")
    func aiAction() {
        let clip = Clip(id: 7, text: "Decidimos mantener el alcance actual", kind: .text)
        let result = SearchEngine.search("resumir", in: SearchInput(clips: [clip])).first

        #expect(result?.id == "verb-summarise")
        #expect(result?.actionID == "ai.verb.summarise")
        #expect(result?.kind == .answer)
        #expect(result?.payload == "summarise\u{1F}Decidimos mantener el alcance actual")
    }

    @Test("brain launchpad does not duplicate its stable open action")
    func brainLaunchpadIsUnique() {
        let results = SearchEngine.search("cerebro", in: SearchInput())
        let brainResults = results.filter { $0.actionID == "brain.open" }

        #expect(brainResults.count == 1)
        #expect(brainResults.first?.id == "brain-open")
    }

    @Test("file verbs resolve to stable actions with a path argument")
    func fileActionsCarryTheirPath() {
        let result = SearchEngine.search("open file /tmp/brief.md", in: SearchInput())
            .first { $0.actionID == "files.open" }

        #expect(result?.kind == .file)
        #expect(result?.payload == "/tmp/brief.md")
    }
}
