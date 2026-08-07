import AppKit
import ApplicationServices
import AVFoundation

/// BeLauncher asks for exactly one optional permission, and only at the moment it is needed.
/// Search, snippets, clipboard history and workflows all work without it.
@MainActor
enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    @discardableResult
    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// The one the app leaned on hardest and never mentioned.
    ///
    /// Every system command and half the flow steps go through Apple Events to System Events.
    /// Without this the flow named "enfoque" runs, reports success and changes nothing — the worst
    /// possible failure, because it looks like the feature is broken rather than unpermitted.
    ///
    /// `AEDeterminePermissionToAutomateTarget` is the only way to ask macOS the state without
    /// firing a real event. `askUserIfNeeded: false` reads it silently; `true` triggers the system
    /// prompt, which is what the onboarding toggle wants.
    static func automationGranted(askUserIfNeeded: Bool = false) -> Bool {
        var target = AEAddressDesc()
        let bundleID = "com.apple.systemevents"
        let status = bundleID.withCString { pointer -> OSErr in
            AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &target)
        }
        guard status == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, askUserIfNeeded
        ) == noErr
    }

    /// Opens the exact pane, because "grant Automation" sends people hunting through System
    /// Settings and Automation is not where anybody looks first.
    static func openAutomationSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Explains first, opens System Settings second — never the other way round.
    /// Returns true when the permission is already granted.
    @discardableResult
    static func requestAccessibility(reason: String) -> Bool {
        if accessibilityGranted { return true }

        let alert = NSAlert()
        alert.messageText = "BeLauncher needs Accessibility permission"
        alert.informativeText = """
            \(reason)

            macOS only lets an app press ⌘V in another app if you grant Accessibility \
            permission. BeLauncher uses it for nothing else: it does not read your screen, \
            your keystrokes or the contents of other apps.

            You can skip this. Everything else in BeLauncher keeps working, and pasting stays \
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
