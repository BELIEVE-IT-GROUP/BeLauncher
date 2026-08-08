import AppKit
import ApplicationServices
import AVFoundation
import AVFAudio

/// BeLauncher asks for exactly one optional permission, and only at the moment it is needed.
/// Search, snippets, clipboard history and workflows all work without it.
@MainActor
enum Permissions {
    private static var microphoneRequest: Task<Bool, Never>?

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static var microphoneGranted: Bool {
        microphoneStatus(for: AVAudioApplication.shared.recordPermission) == .authorized
    }

    static var microphoneStatus: AVAuthorizationStatus {
        microphoneStatus(for: AVAudioApplication.shared.recordPermission)
    }

    /// `AVAudioRecorder` is the recorder used by notes, dictation and calls, so its own authority
    /// is the single source of truth. Combining it with a second API can create a false denial
    /// while two framework views of the same TCC decision are settling.
    static func microphoneStatus(
        for permission: AVAudioApplication.recordPermission
    ) -> AVAuthorizationStatus {
        switch permission {
        case .granted: .authorized
        case .denied: .denied
        case .undetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    @discardableResult
    static func requestMicrophone() async -> Bool {
        if let microphoneRequest {
            return await microphoneRequest.value
        }
        let request = Task { @MainActor in
            await requestMicrophoneOnce()
        }
        microphoneRequest = request
        let granted = await request.value
        microphoneRequest = nil
        return granted
    }

    private static func requestMicrophoneOnce() async -> Bool {
        // A menu-bar agent is not an active application when its menu item is clicked. Give TCC
        // a real foreground application during the request; otherwise macOS can complete the
        // callback without presenting the prompt and without registering the bundle in Privacy
        // > Microphone. Restore the accessory policy after the prompt is dismissed.
        let wasAccessory = NSApp.activationPolicy() == .accessory
        if wasAccessory { _ = NSApp.setActivationPolicy(.regular) }
        defer {
            if wasAccessory { _ = NSApp.setActivationPolicy(.accessory) }
        }
        NSApp.activate(ignoringOtherApps: true)

        var granted = AVAudioApplication.shared.recordPermission == .granted
        if AVAudioApplication.shared.recordPermission == .undetermined {
            granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

        if !granted { openMicrophoneSettings() }
        return granted
    }

    static func openMicrophoneSettings() {
        openPrivacyPane("Privacy_Microphone")
    }

    static func openScreenRecordingSettings() {
        openPrivacyPane("Privacy_ScreenCapture")
    }

    /// There is no prompt API for Full Disk Access. We can only probe a protected local source
    /// and take the person to the exact System Settings pane when the probe fails.
    static var fullDiskAccessLikely: Bool {
        fullDiskAccessLikely(home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    static func fullDiskAccessLikely(home: String) -> Bool {
        let manager = FileManager.default
        if let mail = LocalMailConnector.mailRoot(home: home),
           (try? manager.contentsOfDirectory(atPath: mail.path)) != nil {
            return true
        }
        let paths = [
            "\(home)/Library/Messages/chat.db",
            "\(home)/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite",
        ]
        let existing = paths.filter { manager.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return false }
        return existing.contains { path in
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: 1)) != nil
        }
    }

    static func openFullDiskAccessSettings() {
        openPrivacyPane("Privacy_AllFiles")
    }

    static func prepareForPermissionPrompt() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
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
