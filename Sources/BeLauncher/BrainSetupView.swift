import SwiftUI
import AppKit
import BeLauncherCore

/// Getting the meaning model onto the machine, as a screen instead of as a paragraph in the docs.
///
/// The headline feature of the brain is that it finds by meaning, and on a fresh Mac it silently
/// does not: the model is missing, search falls back to words, and nothing anywhere says so. A
/// link in a README does not fix that, because the person never reads it — they conclude the
/// search is bad. So this is a screen: one reason, one button, real progress, and a way out that
/// is not a dead end.
@MainActor
struct BrainSetupView: View {
    let installer: ModelInstaller
    /// Called when the person chooses to carry on without the model. Never disabled: an offer
    /// with no way out is a demand.
    var onSkip: () -> Void = {}
    /// Called when they close the screen after it finished.
    var onFinish: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Mascot(height: 108, isWorking: installer.phase.isBusy)
                    .padding(.top, 26)

                VStack(spacing: 10) {
                    Text(isDone ? BrainSetupCopy.setupDone : BrainSetupCopy.setupTitle)
                        .font(.system(size: 22, weight: .semibold))
                        .multilineTextAlignment(.center)
                    if !isDone {
                        Text(BrainSetupCopy.setupWhy)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 420)

                ModelInstallControls(installer: installer, showsCost: true)
                    .frame(maxWidth: 420)

                if isDone {
                    Button(L("Close"), action: onFinish)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    VStack(spacing: 4) {
                        Button(BrainSetupCopy.setupSkip, action: onSkip)
                            .buttonStyle(.link)
                        Text(BrainSetupCopy.setupLater)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .frame(minWidth: 420, minHeight: 460)
    }

    private var isDone: Bool {
        if case .ready = installer.phase { return true }
        return false
    }
}

/// The install flow itself, without the framing, so the standalone screen and the Ajustes section
/// are the same code. Two implementations of "download the model" would drift the day one of them
/// grows a state the other does not have — and the states here are the whole point.
@MainActor
struct ModelInstallControls: View {
    let installer: ModelInstaller
    /// The size-and-privacy line. Shown on the setup screen, redundant inside Ajustes where the
    /// model line already says where it runs.
    var showsCost = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsCost, !isReady {
                Label(BrainSetupCopy.setupCost, systemImage: "internaldrive")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch installer.phase {
            // Empty state, not a busy one. Both used to paint the same spinner, so a section that
            // was doing nothing span forever under "Mirando qué hay en este Mac…".
            case .idle:
                VStack(alignment: .leading, spacing: 8) {
                    Text(ModelInstall.message(for: .idle))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("Look at what is on this Mac")) { Task { await installer.check() } }
                }

            case .checking:
                busyLine(L("Looking at what is on this Mac…"))

            case .ready(let model):
                Label("\(model) instalado y respondiendo.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.green)

            case .notReady(let state):
                plan(for: state)

            case .installingOllama:
                busyLine(ModelInstall.message(for: installer.phase))

            case .startingOllama:
                busyLine(ModelInstall.message(for: installer.phase))

            case .downloading(let progress):
                downloading(progress)

            // Cancelling is not a failure and not "nothing happened": it says what became of the
            // download and offers the only button that matters, which is starting it again.
            case .cancelled:
                VStack(alignment: .leading, spacing: 8) {
                    Text(ModelInstall.message(for: .cancelled))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button(ModelInstall.Step.pullModel.title) { installer.downloadModel() }
                            .buttonStyle(.borderedProminent)
                        Button("Volver a mirar") { Task { await installer.check() } }
                            .buttonStyle(.link).font(.system(size: 11))
                    }
                }

            case .insufficientSpace(let free):
                problem(ModelInstall.spaceMessage(freeBytes: free),
                        fix: L("Free up some space and try again."),
                        retry: { installer.downloadModel() })

            case .failed(let reason):
                problem(reason, fix: nil, retry: { Task { await installer.check() } })
            }
        }
        .animation(.easeInOut(duration: 0.2), value: installer.phase)
    }

    private var isReady: Bool {
        if case .ready = installer.phase { return true }
        return false
    }

    // MARK: - What is missing, and the one button that fixes the first thing

    /// Only the next step gets a button. Showing three at once invites pressing the third, which
    /// cannot work until the first two happened, and a button that does nothing is worse than no
    /// button.
    @ViewBuilder
    private func plan(for state: ModelInstall.MachineState) -> some View {
        let steps = ModelInstall.plan(for: state)

        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                HStack(spacing: 8) {
                    Image(systemName: index == 0 ? "circle" : "circle.dotted")
                        .foregroundStyle(index == 0 ? AnyShapeStyle(Theme.cyan)
                                                    : AnyShapeStyle(.tertiary))
                        .font(.system(size: 11))
                    Text(step.title)
                        .font(.system(size: 12))
                        .foregroundStyle(index == 0 ? .primary : .secondary)
                }
            }
        }

        if let next = steps.first {
            switch next {
            case .installOllama:
                VStack(alignment: .leading, spacing: 8) {
                    Text(BrainSetupCopy.installExplanation)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button(BrainSetupCopy.installByHand) {
                            installer.openOllamaDownloadPage()
                        }
                        .buttonStyle(.borderedProminent)
                        if installer.hasHomebrew {
                            Button(BrainSetupCopy.installByHomebrew) {
                                installer.installWithHomebrew()
                            }
                        }
                    }
                    Button(L("I installed it already, look again")) {
                        Task { await installer.check() }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }

            case .startOllama:
                Button(ModelInstall.Step.startOllama.title) { installer.startOllama() }
                    .buttonStyle(.borderedProminent)

            case .pullModel:
                Button(ModelInstall.Step.pullModel.title) { installer.downloadModel() }
                    .buttonStyle(.borderedProminent)
            }
        }

        Text(ModelInstall.wordSearchStillWorks)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Downloading

    /// A determinate bar, fed by Ollama's own byte counts. A spinner for a two-gigabyte download
    /// is indistinguishable from a hang, which is how people end up force-quitting halfway.
    @ViewBuilder
    private func downloading(_ progress: ModelInstall.PullProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
            HStack {
                Text(ModelInstall.describe(progress))
                    .font(.system(size: 12))
                    .monospacedDigit()
                Spacer()
                Button(L("Cancel")) { installer.cancelDownload() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            Text(BrainSetupCopy.setupKeepUsing)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Pieces

    private func busyLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    /// Every failure says what happened and what to do next, in that order, with a way to try
    /// again. A red sentence on its own is a dead end.
    private func problem(_ what: String, fix: String?, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(what, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.destructive)
                .fixedSize(horizontal: false, vertical: true)
            if let fix {
                Text(fix).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(L("Try again"), action: retry)
        }
    }
}

/// Opens the setup screen in its own window.
///
/// Lives here rather than in the app delegate because the screen owns its own installer: the
/// download keeps running while the person uses the launcher, and closing the window must not
/// cancel it.
@MainActor
enum BrainSetupWindow {
    private static var window: NSWindow?
    private static let installer = ModelInstaller()

    /// True while there is a reason to show this at all, so a caller can decide without building
    /// the window first. Answering needs to look at the machine, which is why it is async.
    static func isNeeded() async -> Bool {
        await installer.check()
        if case .ready = installer.phase { return false }
        return true
    }

    /// `place` comes from the app delegate, which knows where the person is looking. Passed in
    /// rather than reached for: `center()` centres on whatever macOS calls the main screen, which
    /// on a second display is usually not the one being used.
    static func present(place: ((NSWindow) -> Void)? = nil) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = BrainSetupView(installer: installer, onSkip: close, onFinish: close)
        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        created.title = L("Get the brain ready")
        created.contentViewController = NSHostingController(rootView: view)
        created.isReleasedWhenClosed = false
        if let place { place(created) } else { created.center() }
        window = created
        NSApp.activate(ignoringOtherApps: true)
        created.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.orderOut(nil)
    }
}
