import AppKit
import BeLauncherCore

/// Carries out the system commands.
///
/// Every command is a fixed implementation chosen by us: the user cannot edit what runs, so the
/// promise that BeLauncher never executes arbitrary scripts still holds. The AppleScript snippets
/// here are constants, and macOS asks for Automation permission the first time each one is used.
@MainActor
enum SystemCommandRunner {

    /// Returns a message when something went wrong, so the caller can say so out loud. A launcher
    /// that silently does nothing — typically a missing Automation permission — is worse than one
    /// that fails loudly.
    @discardableResult
    static func run(_ rawKind: String, confirm: (String) -> Bool) -> String? {
        guard let command = SystemCommand.all.first(where: { $0.kind.rawValue == rawKind }) else {
            return L("That command no longer exists.")
        }
        if command.needsConfirmation, !confirm(command.title) { return nil }
        lastFailure = nil

        switch command.kind {
        case .openBrain:
            // Handled by the app before it ever reaches here: it opens a window of ours rather
            // than asking macOS for anything. Present so the switch stays exhaustive and a future
            // caller does not get silence.
            return nil

        case .lockScreen:
            // The same path the Apple menu uses; no Automation prompt.
            shell("/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession", ["-suspend"])

        case .sleepDisplay:
            shell("/usr/bin/pmset", ["displaysleepnow"])

        case .sleepMac:
            applescript("tell application \"System Events\" to sleep")

        case .screenSaver:
            NSWorkspace.shared.open(URL(fileURLWithPath:
                "/System/Library/CoreServices/ScreenSaverEngine.app"))

        case .toggleDarkMode:
            applescript("""
                tell application "System Events" to tell appearance preferences \
                to set dark mode to not dark mode
                """)

        case .toggleDoNotDisturb:
            // No public API for Focus; take the user to the pane that owns it.
            openSettings(pane: "com.apple.Focus-Settings.extension")

        case .toggleBluetooth:
            openSettings(pane: "com.apple.BluetoothSettings")

        case .toggleWiFi:
            openSettings(pane: "com.apple.wifi-settings-extension")

        case .emptyTrash:
            applescript("tell application \"Finder\" to empty trash")

        case .openTrash:
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))

        case .openDownloads:
            open(.downloadsDirectory)

        case .openDesktop:
            open(.desktopDirectory)

        case .openHome:
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)

        case .showDesktop:
            applescript("tell application \"System Events\" to key code 103")   // F11

        case .volumeMute:
            applescript("set volume with output muted")

        case .ejectDisks:
            applescript("tell application \"Finder\" to eject (every disk whose ejectable is true)")

        case .logOut:
            applescript("tell application \"System Events\" to log out")

        case .restart:
            applescript("tell application \"System Events\" to restart")

        case .shutDown:
            applescript("tell application \"System Events\" to shut down")

        case .restartBeLauncher:
            relaunch()

        case .quitBeLauncher:
            NSApp.terminate(nil)
        }
        return lastFailure
    }

    private static var lastFailure: String?

    // MARK: - Helpers

    private static func open(_ directory: FileManager.SearchPathDirectory) {
        guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else { return }
        NSWorkspace.shared.open(url)
    }

    private static func openSettings(pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:\(pane)")!)
    }

    private static func shell(_ path: String, _ arguments: [String]) {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            lastFailure = L("macOS does not have %@ where it was expected.", (path as NSString).lastPathComponent)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments          // arguments, never a shell string
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            lastFailure = L("It could not be run: %@", error.localizedDescription)
        }
    }

    /// Constant scripts only. macOS shows its own Automation prompt the first time.
    private static func applescript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return }
        NSLog("BeLauncher: system command failed: \(error)")
        // -1743 is macOS refusing Automation; anything else is a genuine failure.
        let code = error[NSAppleScript.errorNumber] as? Int ?? 0
        lastFailure = code == -1743
            ? L("macOS blocked this. Allow BeLauncher in Settings › Privacy › Automation.")
            : (error[NSAppleScript.errorMessage] as? String ?? L("The command could not be completed."))
    }

    private static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
