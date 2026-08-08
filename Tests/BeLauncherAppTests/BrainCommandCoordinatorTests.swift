import Testing
@testable import BeLauncher

@MainActor
@Suite("Shared Brain command runs")
struct BrainCommandCoordinatorTests {
    @Test("a cancelled question cannot finish a newer command")
    func staleRunCannotFinishNewerRun() {
        let coordinator = BrainCommandCoordinator()
        coordinator.begin(id: "old", label: "old", source: "test")
        coordinator.begin(id: "new", label: "new", source: "test")

        coordinator.finish(id: "old", cancelled: true)

        #expect(coordinator.current?.id == "new")
        #expect(coordinator.current?.state == .running)
    }

    @Test("the current run can be cancelled through its shared action")
    func currentRunCancellation() {
        let coordinator = BrainCommandCoordinator()
        var cancelled = false
        coordinator.begin(id: "run", label: "run", source: "test",
                          cancel: { cancelled = true })

        coordinator.cancel()

        #expect(cancelled)
        #expect(coordinator.current?.state == .cancelling)
    }
}
