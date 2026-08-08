import SwiftUI
import AppKit
import BeLauncherCore

/// What the brain holds, in numbers a person can check against what they know they wrote.
///
/// This replaces the block that lived inside `SettingsView`, and it exists for one reason: nobody
/// hands their working memory to something they have to take at its word. "Tu cerebro está listo"
/// is a claim. "1.240 fragmentos, 900 entienden lo que quieres decir, 12 ratos de trabajo, 41
/// nombres conocidos" is a set of numbers that can be wrong, and being able to catch it being
/// wrong is exactly what makes it usable.
///
/// Three states, all real: counting while the numbers are being read, the empty one saying so
/// instead of showing five zeros with no explanation, and a failure that names what happened.
@MainActor
struct BrainStatusView: View {
    @Bindable var model: SettingsModel
    let installer: ModelInstaller
    @State private var health = CapabilityHealth()
    @State private var selectedRun: ActionRunSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.brainError {
                Failure(text: error) { model.refreshBrainState() }
            } else if let readout = model.brainReadout {
                Headline(readout: readout)

                if readout.passages > 0 {
                    Counts(model: model)
                    if !readout.needsModel {
                        ProgressView(value: readout.percent)
                            .progressViewStyle(.linear)
                            .opacity(readout.isComplete ? 0.35 : 1)
                    }
                }

                Label(readout.engineLine,
                      systemImage: readout.needsModel ? "questionmark.circle" : "cpu")
                    .font(.system(size: 11.5))
                    .foregroundStyle(readout.needsModel ? Color.primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(model.brainIsLocal ? PrivacyCopy.Brain.localLine : PrivacyCopy.Brain.remoteLine)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label(model.corpusStatusLine, systemImage: model.corpusPhase == "failed"
                      ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 11.5))
                    .foregroundStyle(model.corpusPhase == "failed" ? .orange : .secondary)
                if let progress = model.ingestionProgress,
                   progress.phase == .writing,
                   let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                    Text(L("%@ of %@ items · %@ passages",
                           String(progress.completedItems), String(progress.totalItems),
                           String(progress.writtenPassages)))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if let run = model.corpusRunHistory.first {
                    Text(L("Last run: %@ · %@ passages · %@ s",
                           model.corpusSourceLabel(run.source), String(run.written),
                           String(format: "%.1f", run.duration)))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                if !model.interruptedActionRuns.isEmpty {
                    Label(L("%@ action(s) were interrupted and need your review.",
                            String(model.interruptedActionRuns.count)),
                          systemImage: "exclamationmark.arrow.circlepath")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                    ForEach(model.interruptedActionRuns.prefix(3)) { run in
                        HStack(spacing: 7) {
                            Text(run.intent).font(.system(size: 10.5))
                                .lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 4)
                            Button(run.mission == nil ? L("Unavailable") : L("Review")) {
                                model.reviewInterrupted(run.id)
                            }
                            .buttonStyle(.link).font(.system(size: 10.5))
                            .disabled(run.mission == nil)
                        }
                    }
                }
                if !model.actionRuns.isEmpty {
                    RecentMissionList(runs: model.recentActionRuns) { selectedRun = $0 }
                        .padding(.top, 2)
                }
                if model.corpusHasCheckpoint {
                    Label(L("A previous capture will resume safely."),
                          systemImage: "arrow.clockwise.circle")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.cyan)
                }
                if let milliseconds = model.startupReadyMS {
                    Label(L("Launcher ready in %@ ms", String(milliseconds)),
                          systemImage: "speedometer")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Label(health.fullDiskAccess.isReady
                          ? L("Deep local sources ready")
                          : L("Full Disk Access needed for Mail, Messages and Notes"),
                          systemImage: health.fullDiskAccess.isReady ? "lock.open" : "lock")
                        .font(.system(size: 10.5))
                        .foregroundStyle(health.fullDiskAccess.isReady ? Color.secondary : Color.orange)
                    if !health.fullDiskAccess.isReady {
                        Button(L("Open settings")) {
                            health.openFullDiskAccessSettings()
                        }
                        .buttonStyle(.link).font(.system(size: 10.5))
                    }
                }
                if let problem = model.corpusLastProblem, model.corpusPhase == "failed" {
                    Text(problem).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                // Only when there is something to solve. Showing an installer to somebody who
                // already installed it is noise.
                if readout.needsModel {
                    ModelInstallControls(installer: installer)
                        .padding(.top, 2)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(PrivacyCopy.Brain.counting)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button(model.brainRebuilding
                       ? BrainSetupCopy.rebuildRunning : BrainSetupCopy.rebuildTitle) {
                    model.rebuildIndex()
                }
                .disabled(model.brainRebuilding)
                if model.brainRebuilding { ProgressView().controlSize(.small) }
                Spacer()
                Button("Actualizar") { model.refreshBrainState() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
            Text(BrainSetupCopy.rebuildExplanation)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status = model.brainStatus {
                Text(status)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.brainRebuilding)
        .sheet(isPresented: Binding(get: { selectedRun != nil },
                                    set: { if !$0 { selectedRun = nil } })) {
            if let selectedRun {
                MissionRunDetail(run: selectedRun) {
                    model.reviewInterrupted(selectedRun.id)
                    self.selectedRun = nil
                }
            }
        }
    }
}

@MainActor
private struct RecentMissionList: View {
    let runs: [ActionRunSnapshot]
    let select: (ActionRunSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("Recent missions"), systemImage: "clock.arrow.circlepath")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                let statusColor: Color = {
                    switch run.state {
                    case .completed: return .green
                    case .failed, .interrupted: return .orange
                    default: return .secondary
                    }
                }()
                Button { select(run) } label: {
                    HStack(spacing: 7) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(run.intent).font(.system(size: 10.5))
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(run.state.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(run.state == .completed ? Color.secondary : Color.orange)
                        Text(run.updatedAt, style: .relative)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .help(L("Open mission details"))
            }
        }
    }
}

@MainActor
private struct MissionRunDetail: View {
    let run: ActionRunSnapshot
    let review: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(run.intent).font(.system(size: 15, weight: .semibold))
                    Text(run.state.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(run.updatedAt, style: .relative)
                    .font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            Divider()
            if !run.steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Steps")).font(.caption.weight(.semibold))
                    ForEach(Array(run.steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .top, spacing: 7) {
                            Text(step.outcome == "done" ? "✓" : step.outcome == "failed" ? "✗" : "·")
                                .foregroundStyle(step.outcome == "failed" ? Color.orange : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title).font(.system(size: 11.5))
                                if !step.detail.isEmpty {
                                    Text(step.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            if let receipt = run.receipt, !receipt.isEmpty {
                Text(L("Receipt")).font(.caption.weight(.semibold))
                ScrollView {
                    Text(receipt).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(9)
                .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            } else if let failure = run.failure, !failure.isEmpty {
                Text(failure).font(.system(size: 11)).foregroundStyle(.orange)
                    .textSelection(.enabled)
            } else {
                Text(L("This run has not produced a receipt yet."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if run.state == .interrupted, run.mission != nil {
                    Button(L("Review and approve again"), action: review)
                        .buttonStyle(.borderedProminent)
                }
                Button(L("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(minWidth: 430, minHeight: 260)
    }
}

// MARK: - Pieces

@MainActor
private struct Headline: View {
    let readout: BrainSetupCopy.IndexReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(readout.passages == 0 ? PrivacyCopy.Brain.emptyHeadline : readout.headline)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(readout.passages == 0 ? PrivacyCopy.Brain.emptyDetail : readout.detail)
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The five numbers, in a grid that reflows rather than clipping when the window narrows.
@MainActor
private struct Counts: View {
    @Bindable var model: SettingsModel

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)],
                  alignment: .leading, spacing: 8) {
            ForEach(model.brainCards) { card in
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.value)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.cyan)
                    Text(card.label)
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(card.hint)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.white.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.white.opacity(0.07)))
            }
        }
    }
}

@MainActor
private struct Failure: View {
    let text: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Actualizar", action: retry).controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.destructive.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.destructive).frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
        }
    }
}
