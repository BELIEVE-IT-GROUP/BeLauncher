import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Durable action runs")
@MainActor
struct ActionRunStoreTests {
    private func storePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-run-\(UUID().uuidString)")
            .appendingPathComponent("test.sqlite3").path
    }

    private func store() throws -> Store {
        try Store(path: storePath())
    }

    @Test("an interrupted action is surfaced after reopening")
    func interruptionIsVisible() throws {
        let path = storePath()
        let mission = Mission(intent: "ordenar descargas", state: .running,
                              steps: [PlannedStep(title: "Abrir Downloads", action: .openFile(path: "/tmp/Downloads"))])
        do {
            let first = try Store(path: path)
            first.saveActionRun(ActionRunSnapshot(id: "run-1", intent: "ordenar descargas", mission: mission))
            #expect(first.actionRuns().first?.state == .running)
        }

        let reopened = try Store(path: path)
        let recovered = try #require(reopened.actionRuns().first)
        #expect(recovered.state == .interrupted)
        #expect(recovered.failure != nil)
        #expect(recovered.mission?.intent == "ordenar descargas")
    }

    @Test("a finished action keeps its receipt and step outcomes")
    func finishedRunRoundTrips() throws {
        let store = try store()
        let run = ActionRunSnapshot(
            id: "run-2", intent: "enfoque", state: .completed,
            steps: [.init(id: "step-1", title: "Abrir proyecto", outcome: "done", detail: "ok")],
            finishedAt: Date(timeIntervalSince1970: 20), receipt: "# Enfoque\n\nHecho")
        store.saveActionRun(run)
        #expect(store.actionRuns().first == run)
    }

    @Test("an interrupted run reopens for approval without replaying any step")
    func interruptedRunBecomesFreshApprovalDraft() throws {
        let originalSteps = [
            PlannedStep(id: "step-1", title: "Abrir proyecto", action: .openFile(path: "/tmp/project"),
                        outcome: .done, detail: "ya ocurrió"),
            PlannedStep(id: "step-2", title: "Mover archivo", action: .moveToTrash(path: "/tmp/file"),
                        outcome: .failed, detail: "se cortó")
        ]
        let mission = Mission(id: "mission-review", intent: "retomar proyecto", state: .running,
                              steps: originalSteps, finishedAt: Date(), failure: "se cortó")
        let snapshot = ActionRunSnapshot(id: "run-review", intent: mission.intent,
                                         mission: mission, state: .interrupted,
                                         finishedAt: Date(), failure: "la app se cerró")

        let reopened = try #require(snapshot.missionForReview())
        #expect(reopened.id == mission.id)
        #expect(reopened.intent == mission.intent)
        #expect(reopened.state == .awaitingApproval)
        #expect(reopened.finishedAt == nil)
        #expect(reopened.failure == nil)
        #expect(reopened.steps.map(\.id) == originalSteps.map(\.id))
        #expect(reopened.steps.map(\.action) == originalSteps.map(\.action))
        #expect(reopened.steps.allSatisfy { $0.outcome == .pending && $0.detail.isEmpty })
        #expect(snapshot.state == .interrupted)
        #expect(snapshot.receipt == nil)
    }

    @Test("a completed run cannot be turned into a review draft")
    func onlyInterruptedRunsCanBeReviewed() {
        let snapshot = ActionRunSnapshot(id: "done", intent: "ya hecho", state: .completed)
        #expect(snapshot.missionForReview() == nil)
    }

    @Test("a draft round-trips its executable plan without running it")
    func draftRoundTrips() throws {
        let store = try store()
        let mission = Mission(intent: "enfoque", state: .awaitingApproval, steps: [
            PlannedStep(title: "Temporizador", action: .startTimer(minutes: 50, label: "Focus"))
        ])
        let draft = ActionDraftSnapshot(mission: mission)
        store.saveActionDraft(draft)
        let recovered = try #require(store.actionDrafts().first)
        #expect(recovered.mission == mission)
        #expect(store.actionRuns().isEmpty)
    }
}
