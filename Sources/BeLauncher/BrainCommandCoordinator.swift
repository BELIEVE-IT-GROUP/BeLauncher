import Foundation

/// One observable execution state shared by the launcher and the Brain.
///
/// The command can start in either surface, but there must be one answer to "what is running?"
/// and one cancellation path. The coordinator deliberately owns state, not business logic; the
/// AppDelegate still performs the approved actions and writes the receipt.
@MainActor
@Observable
final class BrainCommandCoordinator {
    struct Run: Equatable, Identifiable {
        enum State: Equatable { case running, cancelling, finished, failed, cancelled }

        let id: String
        let label: String
        let source: String
        let startedAt: Date
        var state: State
    }

    private(set) var current: Run?
    private var cancelAction: (() -> Void)?

    func begin(id: String = UUID().uuidString, label: String, source: String,
               cancel: (() -> Void)? = nil) {
        current = Run(id: id, label: label, source: source, startedAt: .now, state: .running)
        cancelAction = cancel
    }

    func setCancelAction(_ action: @escaping () -> Void) {
        cancelAction = action
    }

    func cancel() {
        guard var run = current, run.state == .running else { return }
        run.state = .cancelling
        current = run
        cancelAction?()
    }

    func finish(cancelled: Bool = false, failed: Bool = false) {
        guard var run = current else { return }
        run.state = cancelled ? .cancelled : (failed ? .failed : .finished)
        current = run
        cancelAction = nil
    }

    /// A late task must not finish a newer command that started after it was cancelled.
    func finish(id: String, cancelled: Bool = false, failed: Bool = false) {
        guard current?.id == id else { return }
        finish(cancelled: cancelled, failed: failed)
    }

    func clear() {
        current = nil
        cancelAction = nil
    }
}
