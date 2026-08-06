import SwiftUI
import AppKit
import BeLauncherCore

/// Runs agent commands and keeps the tray.
///
/// The decisions all live in `AgentDriver` and `MissionTray`; this is the part that gathers real
/// context, calls a real model, and carries out real actions. Splitting it that way is what makes
/// an agent that touches your Mac testable at all.
///
/// Nothing here runs unattended without leaving the six things a mission owes you: plan, sources,
/// what it did, what it cost, which permissions it used and what can be undone.
@MainActor
@Observable
final class AgentRunner {
    private(set) var tray = MissionTray()
    /// The run currently on screen in the launcher, if any.
    private(set) var current: AgentRun?

    private let store: Store
    private let ask: @MainActor (String, Sensitivity) async throws -> String
    private let perform: @MainActor (LauncherModel.Action) -> Void
    private let context: @MainActor (AgentCommand.ContextSource) async -> AgentRun.Finding?
    private let granted: @MainActor (Onboarding.Capability.Kind) -> Bool

    private var tasks: [String: Task<Void, Never>] = [:]

    init(store: Store,
         ask: @escaping @MainActor (String, Sensitivity) async throws -> String,
         perform: @escaping @MainActor (LauncherModel.Action) -> Void,
         context: @escaping @MainActor (AgentCommand.ContextSource) async -> AgentRun.Finding?,
         granted: @escaping @MainActor (Onboarding.Capability.Kind) -> Bool) {
        self.store = store
        self.ask = ask
        self.perform = perform
        self.context = context
        self.granted = granted
    }

    var commands: [AgentCommand] { store.availablePacks().map(\.command) }

    // MARK: - Starting

    /// Starts a command. Long ones go to the tray; short ones stay in the window.
    ///
    /// The split matters: blocking the launcher for four seconds is fine and blocking it for four
    /// minutes is not, and the person should not have to know which is which before they type.
    func start(_ command: AgentCommand, argument: String) {
        guard let pack = store.availablePacks().first(where: { $0.id == command.id }) else { return }
        var run = AgentRun(command: command, argument: argument)

        run = AgentDriver.afterInspecting(run, granted: granted)
        guard run.stage != .awaitingPermission else {
            current = run
            return
        }

        // A canvas is its own window: it is a place you stay in, not a result you glance at.
        if let template = pack.canvasTemplate {
            perform(.openCanvas(template: template, brief: argument))
            current = AgentDriver.finish(run, result: "Lienzo abierto.")
            return
        }

        guard tray.canStartAnother else {
            current = AgentDriver.fail(
                run,
                L("There are already %@ missions under way. Wait for them to finish or cancel one.",
                  String(MissionTray.concurrencyLimit)))
            return
        }

        let mission = TrayMission(id: run.id, intent: run.title, state: .working)
        tray.add(mission)
        current = run

        tasks[run.id] = Task { @MainActor in
            await self.execute(run, pack: pack)
        }
    }

    private func execute(_ started: AgentRun, pack: OutcomePack) async {
        var run = started
        var findings: [AgentRun.Finding] = []
        var permissionsUsed: [String] = []

        // 1. Look at what it was told it may look at, and nothing else.
        for source in pack.reads {
            if let finding = await context(source) {
                findings.append(finding)
                if let permission = source.permission {
                    permissionsUsed.append(permission.rawValue)
                }
            }
        }
        run.findings = findings
        tray.update(run.id) { mission in
            mission.sources = findings.map {
                TrayMission.Source(title: $0.source.label, detail: $0.summary)
            }
            mission.permissionsUsed = permissionsUsed
        }
        tray.note(run.id, did: L("It gathered context from %@ source(s)", String(findings.count)))

        guard !Task.isCancelled else { return }

        // 2. Ask, with the house rules folded in.
        let context = findings.map { "\($0.source.label): \($0.summary)" }
            .joined(separator: "\n")
        let brief = run.argument.isEmpty ? context : "\(run.argument)\n\n\(context)"

        do {
            let answer = try await ask(pack.instruction(with: brief), .personal)
            guard !Task.isCancelled else { return }

            run = AgentDriver.finish(run, result: answer)
            tray.update(run.id) { mission in
                mission.state = .completed
                mission.result = answer
                mission.undoable = [
                    UndoableStep(kind: .restoreClipboard, target: "",
                                 label: L("Put back what was on the clipboard")),
                ]
            }
            tray.note(run.id, did: L("It copied the result to the clipboard"))
            perform(.copyToClipboard(text: answer, cursorOffset: nil))

            // 3. Learn: only that this outcome was useful, never what it said.
            if let lesson = AgentDriver.lesson(from: run) {
                store.observe(lesson.trait, lesson.value)
            }
        } catch {
            let reason = (error as? IntelligenceError)?.description ?? error.localizedDescription
            run = AgentDriver.fail(run, reason)
            tray.update(run.id) { mission in
                mission.state = .failed
                mission.failure = reason
            }
        }
        current = run
        tasks[run.id] = nil
    }

    // MARK: - The tray

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        tray.cancel(id)
        if current?.id == id { current = AgentDriver.cancel(current!) }
    }

    func clearFinished() { tray.clearFinished() }

    func dismissCurrent() { current = nil }

    /// Puts back something a mission did.
    func undo(_ step: UndoableStep) {
        switch step.kind {
        case .restoreClipboard:
            break   // the previous contents are in the history; nothing destructive happened
        case .restoreFromTrash:
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
        case .removeCreatedFile:
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: step.target),
                                               resultingItemURL: nil)
        case .revertMemory:
            perform(.discardCommit(step.target))
        }
    }
}

/// The tray on screen: what is running, what needs you, and what it all did.
@MainActor
struct MissionTrayView: View {
    @Bindable var runner: AgentRunner

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Missions")).font(.system(size: 14, weight: .semibold))
                Spacer()
                if !runner.tray.finished.isEmpty {
                    Button("Limpiar terminadas") { runner.clearFinished() }
                        .controlSize(.small)
                }
            }
            .padding(12)
            Divider()

            if runner.tray.missions.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(L("Nothing under way.")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(L("Type “/” in the launcher to see what can be commissioned."))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(runner.tray.missions) { mission in
                            MissionCard(mission: mission,
                                        cancel: { runner.cancel(mission.id) },
                                        undo: { runner.undo($0) })
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 520, height: 560)
    }
}

@MainActor
private struct MissionCard: View {
    let mission: TrayMission
    let cancel: () -> Void
    let undo: (UndoableStep) -> Void

    @State private var showsReceipt = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: mission.state.symbol)
                        .foregroundStyle(colour).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mission.intent).font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        Text(mission.state.label).font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !mission.state.isFinished {
                        Button(L("Cancel")) { cancel() }.controlSize(.small)
                    }
                }

                if let question = mission.question {
                    Text(question).font(.system(size: 11.5)).foregroundStyle(.orange)
                }
                if let failure = mission.failure {
                    Text(failure).font(.system(size: 11)).foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if !mission.result.isEmpty {
                    Text(mission.result).font(.system(size: 11)).lineLimit(3)
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }

                HStack(spacing: 10) {
                    Button(showsReceipt ? L("Hide the detail") : L("See what it did")) {
                        showsReceipt.toggle()
                    }
                    .controlSize(.small)
                    ForEach(mission.undoable) { step in
                        Button(step.label) { undo(step) }.controlSize(.small)
                    }
                    Spacer()
                    Text(mission.tokensUsed == 0 ? L("no cost") : "≈\(mission.tokensUsed) tokens")
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }

                if showsReceipt {
                    Text(mission.receipt())
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(6)
        }
    }

    private var colour: Color {
        switch mission.state {
        case .completed: .green
        case .failed: .orange
        case .needsDecision, .awaitingPermission: Theme.cyan
        default: .secondary
        }
    }
}
