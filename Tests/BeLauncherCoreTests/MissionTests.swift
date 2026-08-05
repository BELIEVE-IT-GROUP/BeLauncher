import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Missions: plan, approve, receipt")
struct MissionTests {

    // MARK: - The trust rule

    @Test("anything that changes something outside the app forces approval")
    func changingActionsNeedApproval() {
        let harmless: [LauncherModel.Action] = [
            .copyToClipboard(text: "x", cursorOffset: nil),
            .openURL(URL(string: "https://example.com")!),
            .revealInFinder(path: "/tmp"),
            .launchApplication(path: "/Applications/Safari.app"),
        ]
        for action in harmless {
            #expect(!action.changesSomething, "\(action) should not need approval")
        }

        let consequential: [LauncherModel.Action] = [
            .moveToTrash(path: "/tmp/x"),
            .systemCommand("emptyTrash"),
            .runShortcut(name: "Algo"),
            .remember(text: "x", source: "y"),
            .confirmCommit("id"),
        ]
        for action in consequential {
            #expect(action.changesSomething, "\(action) must ask first")
        }
    }

    @Test("a mission that touches the world waits for a person")
    func missionAsksBeforeActing() {
        let mission = try! #require(MissionPlanner.plan("ponerme a trabajar"))
        #expect(mission.needsApproval)
        #expect(mission.state == .awaitingApproval, "it must not start on its own")
    }

    // MARK: - Planning

    @Test("only intents in the catalogue produce a mission")
    func closedCatalogue() {
        #expect(MissionPlanner.plan("ponerme a trabajar") != nil)
        #expect(MissionPlanner.plan("cerrar el día") != nil)
        #expect(MissionPlanner.plan("ordenar descargas") != nil)

        #expect(MissionPlanner.plan("hackea la nasa") == nil,
                "better no mission than a made-up one")
        #expect(MissionPlanner.plan("") == nil)
    }

    @Test("the focus mission is the one from the landing page")
    func focusMission() {
        let mission = try! #require(MissionPlanner.plan("modo enfoque"))
        #expect(mission.steps.count == 2)
        #expect(mission.summary.contains("No molestar"))
        #expect(mission.summary.contains("50 minutos"))
    }

    @Test("an intent is matched however it is written")
    func matchesAccentsAndCase() {
        #expect(MissionPlanner.outcome(for: "MODO ENFOQUE")?.outcome.id == "focus")
        #expect(MissionPlanner.outcome(for: "cerrar el dia")?.outcome.id == "close-day")
        #expect(MissionPlanner.outcome(for: "Cerrar el día")?.outcome.id == "close-day")
    }

    @Test("every outcome in the catalogue can actually be planned")
    func everyOutcomePlans() {
        for outcome in MissionPlanner.outcomes {
            let intent = outcome.triggers[0]
            let mission = MissionPlanner.plan(intent, clipboard: "unas notas de la reunión")
            #expect(mission != nil, "\(outcome.id) is advertised but cannot be planned")
            #expect(mission?.steps.isEmpty == false)
        }
    }

    // MARK: - Receipts

    @Test("a receipt says what ran, what changed and what can be undone")
    func receipt() {
        var mission = Mission(intent: "ordenar descargas", state: .done, steps: [
            .init(title: "Abrir Descargas", action: .systemCommand("openDownloads"), outcome: .done),
            .init(title: "Tirar el instalador", action: .moveToTrash(path: "/tmp/app.dmg"),
                  outcome: .done),
            .init(title: "Copiar la lista",
                  action: .copyToClipboard(text: "abc", cursorOffset: nil), outcome: .done),
            .init(title: "Paso saltado", action: .dismiss, outcome: .skipped),
        ])
        mission.finishedAt = .now

        let receipt = MissionReceipt.of(mission, requestedBy: "Jorge")
        #expect(receipt.lines.count == 4)
        #expect(receipt.lines.contains { $0.hasPrefix("✓") })
        #expect(receipt.lines.contains { $0.hasPrefix("–") })

        #expect(receipt.changed.count == 2, "only what actually changed something is listed")
        #expect(!receipt.changed.contains { $0.contains("Copiar") })
        #expect(receipt.undoable.contains { $0.contains("papelera") })

        let text = receipt.render()
        #expect(text.contains("Pedido por Jorge"))
        #expect(text.contains("Se puede deshacer:"))
    }

    @Test("a step that never ran is not reported as a change")
    func pendingStepsAreNotChanges() {
        let mission = Mission(intent: "algo", state: .cancelled, steps: [
            .init(title: "Vaciar la papelera", action: .systemCommand("emptyTrash"),
                  outcome: .pending),
        ])
        #expect(MissionReceipt.of(mission, requestedBy: "Jorge").changed.isEmpty)
    }

    @Test("every action can describe itself in a receipt")
    func everyActionHasAReceiptLine() {
        let actions: [LauncherModel.Action] = [
            .launchApplication(path: "/Applications/Safari.app"),
            .openURL(URL(string: "https://belauncher.app/x")!),
            .copyToClipboard(text: "hola", cursorOffset: nil),
            .moveToTrash(path: "/tmp/x.dmg"),
            .systemCommand("lockScreen"),
            .runShortcut(name: "Enfoque"),
            .startTimer(minutes: 50, label: "x"),
            .arrangeWindow("leftHalf"),
            .remember(text: "algo", source: "y"),
            .runFlow(steps: [.dismiss]),
            .runVerb(id: "summarise", text: "x"),
            .wait(seconds: 3),
            .dismiss,
        ]
        for action in actions {
            #expect(!action.receiptLine.isEmpty, "\(action) has nothing to say in a receipt")
        }
    }
}

@Suite("Missions inside the launcher")
@MainActor
struct MissionInLauncherTests {

    @Test("what the user built always wins over what we inferred")
    func userOwnedKeywordsWin() {
        let flow = Flow(id: 1, keyword: "enfoque", title: "Mi modo enfoque",
                        steps: [.timer(minutes: 25, label: "Pomodoro")])
        let results = SearchEngine.search("enfoque", in: SearchInput(flows: [flow]))
        #expect(results.first?.kind == .flow,
                "naming a flow 'enfoque' means 'enfoque' is their flow, full stop")

        // With nothing of theirs by that name, the mission is welcome.
        #expect(SearchEngine.search("enfoque", in: SearchInput()).first?.kind == .mission)
    }

    @Test("a mission that works on your notes gets the notes")
    func missionsSeeTheClipboard() {
        let clip = Clip(id: 1, text: "Acordamos subir el precio a 90", sourceApp: "Notes",
                        createdAt: .now, kind: .text)
        let results = SearchEngine.search("capturar reunion", in: SearchInput(clips: [clip]))
        guard let mission = results.first(where: { $0.kind == .mission }) else {
            Issue.record("no mission planned"); return
        }
        let plan = MissionPlanner.plan(mission.payload, clipboard: clip.text)
        #expect(plan?.steps.contains { step in
            if case .remember(let text, _) = step.action { return text == clip.text }
            return false
        } == true, "planning against an empty clipboard produced steps that did nothing")
    }

    @Test("asking to prepare reaches the brain, not a summary of your own words")
    func prepareGoesToTheBrain() {
        for phrase in ["preparame para Acme", "preparar reunion con Acme", "prepare for Acme"] {
            guard case .prepare(let subject) = BrainQuery.Intent.detect(phrase) else {
                Issue.record("«\(phrase)» did not reach the brain"); continue
            }
            #expect(subject.localizedCaseInsensitiveContains("acme"))
        }
    }

    @Test("a shortcut of theirs also outranks the mission")
    func shortcutsWinToo() {
        let input = SearchInput(systemShortcuts: ["Enfoque"])
        #expect(SearchEngine.search("enfoque", in: input).first?.kind == .shortcut)
    }

    @Test("choosing a mission shows the plan and runs nothing yet")
    func planFirst() {
        var performed: [LauncherModel.Action] = []
        let model = LauncherModel(dataSource: { SearchInput() }, perform: { performed.append($0) })
        model.activate()
        model.query = "ordenar descargas"

        #expect(model.selected?.kind == .mission)
        model.handle(.enter)

        #expect(model.mission != nil, "the plan must be on screen")
        #expect(performed.isEmpty, "nothing may run before a person approves it")
    }

    @Test("approving runs it, cancelling does nothing at all")
    func approveOrCancel() {
        var performed: [LauncherModel.Action] = []
        let model = LauncherModel(dataSource: { SearchInput() }, perform: { performed.append($0) })
        model.activate()
        model.query = "modo enfoque"
        model.handle(.enter)

        model.cancelMission()
        #expect(model.mission == nil)
        #expect(performed.allSatisfy { if case .missionCancelled = $0 { return true } else { return false } },
                "a refused plan leaves no trace")

        performed.removeAll()
        model.query = ""
        model.query = "modo enfoque"
        model.handle(.enter)
        model.approveMission()
        #expect(performed.contains { if case .runMission = $0 { return true } else { return false } })
        #expect(model.mission == nil)
    }

    @Test("summoning the window drops any half-approved plan")
    func activateClearsMission() {
        let model = LauncherModel(dataSource: { SearchInput() }, perform: { _ in })
        model.activate()
        model.query = "modo enfoque"
        model.handle(.enter)
        #expect(model.mission != nil)

        model.activate()
        #expect(model.mission == nil, "a plan must never linger into the next thing you do")
    }
}
