import Testing
@testable import BeLauncher
@testable import BeLauncherCore

@Suite("Qué puede leer el launcher al invocarse")
struct LauncherInputNeedsTests {

    @Test("invocar vacío no toca vault, grafo, procesos ni workspaces")
    func emptySummonIsLightweight() {
        let needs = LauncherInputNeeds(query: "", mode: .all)

        #expect(!needs.needsMemories)
        #expect(!needs.needsPendingCommits)
        #expect(!needs.needsWorkGraph)
        #expect(!needs.needsProcesses)
        #expect(!needs.needsWorkspaces)
        #expect(!needs.needsPacks)
        #expect(!needs.needsTraits)
        #expect(!needs.needsCalendar)
    }

    @Test("la historia operacional solo se carga para preguntas del grafo")
    func workGraphIsExplicit() {
        let ordinary = LauncherInputNeeds(query: "atlas", mode: .all)
        let promised = LauncherInputNeeds(query: "what did we promise Andrés", mode: .all)
        let resume = LauncherInputNeeds(query: "pick up where i left off", mode: .all)

        #expect(!ordinary.needsWorkGraph)
        #expect(!ordinary.needsMemories)

        #expect(promised.needsWorkGraph)
        #expect(promised.needsMemories)

        #expect(resume.needsWorkGraph)
        #expect(resume.needsCalendar)
    }

    @Test("el vault solo se carga para preguntas explícitas del brain")
    func vaultIsExplicit() {
        let ordinary = LauncherInputNeeds(query: "pricing", mode: .all)
        let decision = LauncherInputNeeds(query: "what did we decide about pricing", mode: .all)
        let pulse = LauncherInputNeeds(query: "pulse", mode: .all)

        #expect(!ordinary.needsMemories)
        #expect(decision.needsMemories)
        #expect(!decision.needsWorkGraph)

        #expect(pulse.needsMemories)
        #expect(pulse.needsTraits)
    }

    @Test("procesos, workspaces y comandos slash se leen solo cuando se piden")
    func specialSurfacesAreExplicit() {
        #expect(LauncherInputNeeds(query: "cpu", mode: .all).needsProcesses)
        #expect(LauncherInputNeeds(query: "workspaces", mode: .all).needsWorkspaces)
        #expect(LauncherInputNeeds(query: "/proposal", mode: .all).needsPacks)

        let plain = LauncherInputNeeds(query: "safari", mode: .all)
        #expect(!plain.needsProcesses)
        #expect(!plain.needsWorkspaces)
        #expect(!plain.needsPacks)
    }

    @Test("las invocaciones de Notes en inglés abren la superficie de notas")
    func notesAliasesAreRecognized() {
        #expect(LauncherInputNeeds(query: "my notes", mode: .all).needsNotes)
        #expect(LauncherInputNeeds(query: "notes", mode: .all).needsNotes)
        #expect(LauncherInputNeeds(query: "quick note", mode: .all).needsNotes)
    }

    @Test("el modo clipboard no despierta otras superficies aunque el texto parezca comando")
    func clipboardModeStaysLightweight() {
        let process = LauncherInputNeeds(query: "cpu", mode: .clipboard)
        let workspace = LauncherInputNeeds(query: "workspaces", mode: .clipboard)
        let brain = LauncherInputNeeds(query: "what did we decide about pricing", mode: .clipboard)
        let pack = LauncherInputNeeds(query: "/proposal", mode: .clipboard)

        #expect(!process.needsProcesses)
        #expect(!workspace.needsWorkspaces)
        #expect(!brain.needsMemories)
        #expect(!brain.needsWorkGraph)
        #expect(!pack.needsPacks)
    }
}
