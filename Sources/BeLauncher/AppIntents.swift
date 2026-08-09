#if canImport(AppIntents)
import AppIntents
import Foundation

enum BELAppIntentNotification {
    static let openBrain = Notification.Name("com.believe.belauncher.intent.openBrain")
    static let showClipboard = Notification.Name("com.believe.belauncher.intent.showClipboard")
    static let openSettings = Notification.Name("com.believe.belauncher.intent.openSettings")
}

struct OpenBrainIntent: AppIntent {
    static let title: LocalizedStringResource = "Open BeBrain"
    static let description = IntentDescription("Open the local Brain workspace.")

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: BELAppIntentNotification.openBrain, object: nil)
        }
        return .result()
    }
}

struct ShowClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Clipboard"
    static let description = IntentDescription("Open BeLauncher's clipboard surface.")

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: BELAppIntentNotification.showClipboard, object: nil)
        }
        return .result()
    }
}

struct OpenBeLauncherSettingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open BeLauncher Settings"
    static let description = IntentDescription("Open BeLauncher's settings.")

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: BELAppIntentNotification.openSettings, object: nil)
        }
        return .result()
    }
}

struct BeLauncherShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        
            AppShortcut(intent: OpenBrainIntent(),
                        phrases: ["Open the Brain in \(.applicationName)"],
                        shortTitle: "Open Brain", systemImageName: "brain")
            AppShortcut(intent: ShowClipboardIntent(),
                        phrases: ["Show clipboard in \(.applicationName)"],
                        shortTitle: "Clipboard", systemImageName: "doc.on.clipboard")
        AppShortcut(intent: OpenBeLauncherSettingsIntent(),
                        phrases: ["Open \(.applicationName) settings"],
                    shortTitle: "Settings", systemImageName: "gearshape")
    }
}
#endif
