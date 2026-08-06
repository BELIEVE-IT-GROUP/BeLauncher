import AppKit
import SwiftUI
import BeLauncherCore

/// Borderless floating panel that hosts the command window.
/// It grows and shrinks with its content while its top edge stays put.
@MainActor
final class CommandPanel: NSPanel {
    private var topEdge: CGFloat = 0
    private var anchoredScreen: NSScreen?

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
        // The panel appears over whatever is on screen. Following the system appearance meant a
        // launcher summoned over a white page rendered light-on-light and could not be read.
        appearance = NSAppearance(named: .darkAqua)
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

    /// The screen the person is actually looking at.
    ///
    /// `NSScreen.main` is whichever screen macOS considers key, which on a Mac with three
    /// displays is regularly not the one being used — so the launcher opened on another monitor.
    /// Where the pointer is is the honest answer, and it is what every other launcher does.
    private var activeScreen: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    func present() {
        guard let screen = activeScreen else { return }
        // Remembered, so a resize while the window is open does not fling it to another display
        // just because the pointer moved.
        anchoredScreen = screen
        let visible = screen.visibleFrame
        topEdge = visible.maxY - visible.height * 0.16
        reanchor()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        Sounds.play(.opened)
    }

    override func orderOut(_ sender: Any?) {
        let wasVisible = isVisible
        super.orderOut(sender)
        // Only when it was actually on screen: dismissing something already hidden happens on
        // several paths and should not make a noise each time.
        if wasVisible { Sounds.play(.closed) }
    }

    @objc private func reanchor() {
        guard let screen = anchoredScreen ?? activeScreen, topEdge > 0 else { return }
        let size = frame.size
        let origin = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: topEdge - size.height
        )
        guard abs(origin.x - frame.origin.x) > 0.5 || abs(origin.y - frame.origin.y) > 0.5 else { return }
        setFrameOrigin(origin)
    }
}
