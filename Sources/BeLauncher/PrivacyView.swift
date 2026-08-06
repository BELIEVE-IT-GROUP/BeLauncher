import SwiftUI
import AppKit
import BeLauncherCore

/// The three controls that have to exist before the app is allowed to watch anything: stop, look
/// away, forget.
///
/// They were all implemented in `Privacy.swift` and none of them reachable, which is the worst
/// possible arrangement: the code can honestly claim the user is in control and the user has no
/// way to exercise it. Everything here is a front end for something already written and already
/// tested; the only new decisions are where the pause becomes visible from outside this window,
/// and how hard it is to trigger the one action that cannot be undone.
@MainActor
struct PrivacyView: View {
    @Bindable var model: SettingsModel

    @State private var newApp = ""
    @State private var newDomain = ""
    /// Redrawn on a slow tick so "vuelve solo en 47 minutos" does not sit there saying 47 for an
    /// hour. A countdown that does not count is worse than no countdown.
    @State private var now = Date.now

    var body: some View {
        Form {
            Section {
                PauseCard(model: model, now: now)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section(PrivacyCopy.pauseTitle) {
                PauseChoices(model: model)
                Text(PrivacyCopy.pauseExplanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(PrivacyCopy.resumeExplanation)
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(PrivacyCopy.exclusionsTitle) {
                Text(PrivacyCopy.exclusionsExplanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ExclusionList(
                    entries: model.excludedForCapture,
                    emptyLine: PrivacyCopy.appsEmpty,
                    isFactory: { Privacy.excludedByDefault.contains($0) },
                    display: { PrivacyCopy.appName($0) },
                    remove: { model.removeExcludedFromCapture($0) }
                )
                AddRow(text: $newApp, placeholder: PrivacyCopy.addAppPlaceholder,
                       problem: PrivacyCopy.problem(withApp: newApp)) {
                    model.addExcludedFromCapture(newApp)
                    newApp = ""
                }
                if let note = model.exclusionNote {
                    Text(note).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(L("Sites it never looks at")) {
                ExclusionList(
                    entries: model.excludedCaptureDomains,
                    emptyLine: PrivacyCopy.domainsEmpty,
                    isFactory: { Privacy.excludedDomainsByDefault.contains($0) },
                    display: { $0 },
                    remove: { model.removeExcludedDomain($0) }
                )
                AddRow(text: $newDomain, placeholder: PrivacyCopy.addDomainPlaceholder,
                       problem: PrivacyCopy.problem(withDomain: newDomain)) {
                    model.addExcludedDomain(newDomain)
                    newDomain = ""
                }
                Text(PrivacyCopy.defaultsExplanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(PrivacyCopy.forgetTitle) {
                ForgetBlock(model: model)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshPrivacy() }
        .task {
            // Twenty seconds is often enough for the countdown to stay true and rare enough that
            // nobody notices it: the alternative, a per-second timer behind a settings tab, keeps
            // the app awake for a number almost nobody is looking at.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                now = .now
                model.refreshPrivacy()
            }
        }
    }
}

// MARK: - Whether it is watching, said in words

/// The answer, before any control. Coloured and worded, never a bare dot: the two states this card
/// distinguishes are "recording everything you do" and "recording nothing", and those cannot be
/// told apart by a shade of green in the corner of a settings panel.
@MainActor
private struct PauseCard: View {
    @Bindable var model: SettingsModel
    let now: Date

    var body: some View {
        let banner = PrivacyCopy.banner(for: model.privacy, at: now)
        HStack(alignment: .top, spacing: 14) {
            Mascot(height: 52, isWorking: !banner.isPaused)
                .opacity(banner.isPaused ? 0.45 : 1)
                .saturation(banner.isPaused ? 0 : 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(banner.headline)
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(banner.detail)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !banner.resumeTitle.isEmpty {
                Button(banner.resumeTitle) { model.resumeCapture() }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint(banner).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle().fill(tint(banner)).frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
        }
        .animation(.easeInOut(duration: 0.2), value: banner.isPaused)
    }

    private func tint(_ banner: PrivacyCopy.Banner) -> Color {
        banner.isPaused ? Theme.destructive : Theme.cyan
    }
}

/// The four answers to "for how long", as four buttons rather than a date picker.
@MainActor
private struct PauseChoices: View {
    @Bindable var model: SettingsModel

    var body: some View {
        // Wraps instead of squeezing: four Spanish labels on one line stop fitting well before the
        // window reaches its minimum width.
        FlowRow(spacing: 8) {
            ForEach(PrivacyCopy.PauseChoice.allCases) { choice in
                Button(choice.label) { model.pause(choice) }
                    .controlSize(.regular)
            }
        }
    }
}

// MARK: - What it never looks at

@MainActor
private struct ExclusionList: View {
    let entries: [String]
    let emptyLine: String
    let isFactory: (String) -> Bool
    let display: (String) -> String
    let remove: (String) -> Void

    var body: some View {
        if entries.isEmpty {
            Text(emptyLine).font(.caption).foregroundStyle(.secondary)
        }
        ForEach(entries, id: \.self) { entry in
            HStack(spacing: 8) {
                Image(systemName: "eye.slash").foregroundStyle(.secondary)
                    .font(.system(size: 11)).frame(width: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(display(entry)).font(.system(size: 12))
                    if display(entry) != entry {
                        Text(entry).font(.system(size: 10)).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                if isFactory(entry) {
                    Text(L("factory setting"))
                        .font(.system(size: 9.5, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Button { remove(entry) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(L("Take it off the list. It gets looked at again from that moment on."))
            }
        }
    }
}

@MainActor
private struct AddRow: View {
    @Binding var text: String
    let placeholder: String
    let problem: String?
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(placeholder, text: $text)
                    .onSubmit { if problem == nil { add() } }
                Button("Excluir", action: add)
                    .controlSize(.small)
                    .disabled(problem != nil || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Forgetting, which is the only door with no handle on the other side

/// Two gates on purpose. Choosing a period only *counts*; the delete button appears afterwards and
/// names the number it found; pressing it opens a dialog whose default key is Cancelar. So the
/// shortest possible path from a stray click to a permanent delete is: pick a period, read a
/// sentence with a number in it, press a second button, and then choose the button that is not the
/// one Return presses.
@MainActor
private struct ForgetBlock: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(PrivacyCopy.forgetExplanation)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $model.forgetChoice) {
                ForEach(PrivacyCopy.ForgetChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.forgetChoice == .range {
                // Wraps under itself on a narrow window instead of clipping the second picker.
                FlowRow(spacing: 10) {
                    DatePicker(PrivacyCopy.rangeStart, selection: $model.forgetFrom)
                        .datePickerStyle(.compact)
                    DatePicker(PrivacyCopy.rangeEnd, selection: $model.forgetTo)
                        .datePickerStyle(.compact)
                }
                .font(.system(size: 11.5))
                if model.forgetTo < model.forgetFrom {
                    Text(PrivacyCopy.rangeBackwards).font(.caption).foregroundStyle(.orange)
                }
            }

            switch model.forgetState {
            case .idle:
                Button(L("See what would be deleted")) { model.countWhatWouldBeForgotten() }
                    .disabled(model.forgetChoice == .range && model.forgetTo < model.forgetFrom)

            case .counting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(PrivacyCopy.counting).font(.caption).foregroundStyle(.secondary)
                }

            case .ready(let forgetting):
                VStack(alignment: .leading, spacing: 8) {
                    Text(PrivacyCopy.breakdown(forgetting))
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if !forgetting.isEmpty {
                            Button(PrivacyCopy.confirmation(period: model.forgetChoice.label,
                                                            forgetting: forgetting).confirmTitle) {
                                model.confirmAndForget()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.destructive)
                        }
                        Button(L("Go back")) { model.cancelForgetPreview() }
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.destructive.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            case .failed(let reason):
                VStack(alignment: .leading, spacing: 6) {
                    Text(reason).font(.system(size: 12)).foregroundStyle(Theme.destructive)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("Try again")) { model.countWhatWouldBeForgotten() }
                        .controlSize(.small)
                }
            }

            if let done = model.forgetResult {
                Text(done).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.forgetState)
    }
}

// MARK: - A row that wraps

/// Buttons and pickers that move to the next line instead of being squeezed or clipped.
///
/// `HStack` has exactly one strategy when the window narrows, which is to compress its children;
/// with Spanish labels that turns "Hasta que lo reanude yo" into "Hasta que lo…" long before the
/// window hits its minimum size.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - The pause, seen from outside the panel that set it

/// A menu bar item that exists only while capture is off.
///
/// Without this the pause is a trap. You pause for a call, close Ajustes, and the app looks exactly
/// like it always does: same icon, same launcher, same everything, quietly recording nothing for
/// three days. A brain that is paused and looks like it is working is the worst of both worlds —
/// you get neither the privacy you thought you were choosing nor the memory you are paying for.
///
/// It carries the word "En pausa" rather than a second grey glyph, because a menu bar is where
/// icons go to be ignored, and it disappears the moment capture resumes so it never becomes
/// another permanent thing up there.
@MainActor
final class PauseIndicator: NSObject {
    static let shared = PauseIndicator()

    private var item: NSStatusItem?
    private var timer: Timer?
    private weak var model: SettingsModel?

    /// Called on every privacy refresh. Installs, updates or removes the item; safe to call as
    /// often as anybody likes.
    func show(_ state: Privacy.State, model: SettingsModel) {
        self.model = model
        guard let title = PrivacyCopy.menuBarTitle(for: state) else {
            remove()
            return
        }
        let item = self.item ?? install()
        item.button?.title = " " + title
        item.button?.toolTip = PrivacyCopy.menuBarTooltip(for: state)
        item.menu?.items.first?.title = PrivacyCopy.banner(for: state).headline
        startTicking()
    }

    private func install() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "pause.circle.fill",
                                     accessibilityDescription: L("Capture is paused"))
        item.button?.image?.isTemplate = true
        item.button?.imagePosition = .imageLeading
        item.button?.font = .systemFont(ofSize: 12, weight: .medium)

        let menu = NSMenu()
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Always shown: every pause this app can be in is one a person chose, so there is always
        // something to undo. It used to hide itself for a pause the app set by itself when it
        // believed it could tell you were sharing your screen; it cannot, and that pause is gone.
        let resume = NSMenuItem(title: "Reanudar ahora", action: #selector(resume),
                                keyEquivalent: "")
        resume.target = self
        menu.addItem(resume)

        let open = NSMenuItem(title: L("Open privacy…"), action: #selector(openPrivacy),
                              keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        item.menu = menu
        self.item = item
        return item
    }

    private func remove() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
        timer?.invalidate()
        timer = nil
    }

    /// Keeps the remaining time honest and takes the item down by itself when the pause runs out,
    /// so nobody has to open Ajustes to find out that capture came back.
    private func startTicking() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in PauseIndicator.shared.tick() }
        }
    }

    private func tick() {
        guard let model else { return remove() }
        model.refreshPrivacy()
    }

    @objc private func resume() { model?.resumeCapture() }

    @objc private func openPrivacy() {
        model?.requestedSection = "privacy"
        (NSApp.delegate as? AppDelegate)?.openSettings()
    }
}
