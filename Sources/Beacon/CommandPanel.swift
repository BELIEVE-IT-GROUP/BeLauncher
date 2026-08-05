import AppKit
import SwiftUI
import BeaconCore

/// Borderless floating panel that hosts the command window.
/// It grows and shrinks with its content while its top edge stays put.
@MainActor
final class CommandPanel: NSPanel {
    private var topEdge: CGFloat = 0

    init(model: LauncherModel, openSettings: @escaping () -> Void) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 708, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .modalPanel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false            // the SwiftUI layer draws its own, so corners stay clean
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let controller = NSHostingController(rootView: CommandView(model: model, openSettings: openSettings))
        controller.sizingOptions = [.preferredContentSize]
        contentViewController = controller

        NotificationCenter.default.addObserver(
            self, selector: #selector(reanchor),
            name: NSWindow.didResizeNotification, object: self
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        topEdge = visible.maxY - visible.height * 0.16
        reanchor()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    @objc private func reanchor() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first, topEdge > 0 else { return }
        let size = frame.size
        let origin = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: topEdge - size.height
        )
        guard abs(origin.x - frame.origin.x) > 0.5 || abs(origin.y - frame.origin.y) > 0.5 else { return }
        setFrameOrigin(origin)
    }
}
