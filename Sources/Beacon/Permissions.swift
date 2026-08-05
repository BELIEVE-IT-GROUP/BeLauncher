import AppKit
import ApplicationServices

/// Beacon asks for exactly one optional permission, and only at the moment it is needed.
/// Search, snippets, clipboard history and workflows all work without it.
@MainActor
enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Explains first, opens System Settings second — never the other way round.
    /// Returns true when the permission is already granted.
    @discardableResult
    static func requestAccessibility(reason: String) -> Bool {
        if accessibilityGranted { return true }

        let alert = NSAlert()
        alert.messageText = "Beacon needs Accessibility permission"
        alert.informativeText = """
            \(reason)

            macOS only lets an app press ⌘V in another app if you grant Accessibility \
            permission. Beacon uses it for nothing else: it does not read your screen, \
            your keystrokes or the contents of other apps.

            You can skip this. Everything else in Beacon keeps working, and pasting stays \
            a manual ⌘V.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not now")

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        return false
    }

    /// Sends ⌘V to the frontmost app. Silently does nothing without permission.
    static func pasteToFrontmostApp() {
        guard accessibilityGranted, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let v: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
