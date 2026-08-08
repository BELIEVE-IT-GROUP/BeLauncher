import AppKit
import SwiftUI
import BeLauncherCore

/// Small, always-visible confirmation for capture started outside the launcher.
/// The menu-bar item remains available, but the person should never have to guess whether
/// a hotkey worked or where a finished recording went.
@MainActor
final class CaptureStatusPanel: NSPanel {
    private weak var controller: AudioCaptureController?

    init(controller: AudioCaptureController,
         openBrain: @escaping () -> Void,
         newNote: @escaping () -> Void) {
        self.controller = controller
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 116),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        contentViewController = NSHostingController(rootView: CaptureStatusView(
            controller: controller,
            stop: { controller.stopVoiceNote() },
            openBrain: openBrain,
            newNote: newNote))
    }

    func present() {
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 24,
                               y: visible.maxY - frame.height - 24))
        orderFrontRegardless()
    }
}

@MainActor
private struct CaptureStatusView: View {
    @ObservedObject var controller: AudioCaptureController
    let stop: () -> Void
    let openBrain: () -> Void
    let newNote: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .foregroundStyle(controller.isRecording ? .red : Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.stateLabel)
                        .font(.system(size: 13, weight: .semibold))
                    Text(controller.message.isEmpty ? L("Your audio stays on this Mac") : controller.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if let started = controller.recordingStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.elapsed(from: started, to: context.date))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                if controller.isRecording {
                    Button(L("Stop"), action: stop)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else if controller.isTranscribing {
                    ProgressView().controlSize(.small)
                }
                Button(L("Open Brain"), action: openBrain)
                    .buttonStyle(.borderless)
                Button(L("New note"), action: newNote)
                    .buttonStyle(.borderless)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.white.opacity(0.14)))
        .padding(8)
    }

    private var icon: String {
        switch controller.state {
        case .recording: "record.circle.fill"
        case .transcribing: "waveform"
        case .idle: "checkmark.circle.fill"
        }
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private extension AudioCaptureController {
    var isTranscribing: Bool { state == .transcribing }
}
