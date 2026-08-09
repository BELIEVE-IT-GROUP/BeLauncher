#if canImport(AppIntents)
import AppIntents
import Foundation

enum BELAppIntentNotification {
    static let openBrain = Notification.Name("com.believe.belauncher.intent.openBrain")
    static let showClipboard = Notification.Name("com.believe.belauncher.intent.showClipboard")
    static let openSettings = Notification.Name("com.believe.belauncher.intent.openSettings")
    static let recordVoice = Notification.Name("com.believe.belauncher.intent.recordVoice")
    static let dictate = Notification.Name("com.believe.belauncher.intent.dictate")
    static let readScreen = Notification.Name("com.believe.belauncher.intent.readScreen")
    static let quickNote = Notification.Name("com.believe.belauncher.intent.quickNote")
    static let recordCall = Notification.Name("com.believe.belauncher.intent.recordCall")
    static let searchBrain = Notification.Name("com.believe.belauncher.intent.searchBrain")
    static let upcomingMeetings = Notification.Name("com.believe.belauncher.intent.upcomingMeetings")
    static let focus = Notification.Name("com.believe.belauncher.intent.focus")
    static let prepareMeeting = Notification.Name("com.believe.belauncher.intent.prepareMeeting")
    static let openNotes = Notification.Name("com.believe.belauncher.intent.openNotes")
    static let openGraph = Notification.Name("com.believe.belauncher.intent.openGraph")
    static let transcribeLastVoice = Notification.Name("com.believe.belauncher.intent.transcribeLastVoice")
    static let openLauncher = Notification.Name("com.believe.belauncher.intent.openLauncher")
}

private func postBELIntent(_ name: Notification.Name) {
    NotificationCenter.default.post(name: name, object: nil)
}

struct OpenBrainIntent: AppIntent {
    static let title: LocalizedStringResource = "Open BeBrain"
    static let description = IntentDescription("Open the local Brain workspace.")
    static var openAppWhenRun: Bool { true }
    func perform() async throws -> some IntentResult { await MainActor.run { postBELIntent(BELAppIntentNotification.openBrain) }; return .result() }
}

struct ShowClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Clipboard"
    static let description = IntentDescription("Open BeLauncher's clipboard surface.")
    static var openAppWhenRun: Bool { true }
    func perform() async throws -> some IntentResult { await MainActor.run { postBELIntent(BELAppIntentNotification.showClipboard) }; return .result() }
}

struct OpenBeLauncherSettingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open BeLauncher Settings"
    static let description = IntentDescription("Open BeLauncher's settings.")
    static var openAppWhenRun: Bool { true }
    func perform() async throws -> some IntentResult { await MainActor.run { postBELIntent(BELAppIntentNotification.openSettings) }; return .result() }
}

struct RecordVoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Voice Note"
    static let description = IntentDescription("Start or stop a local voice note in BeLauncher.")
    static var openAppWhenRun: Bool { true }
    func perform() async throws -> some IntentResult { await MainActor.run { postBELIntent(BELAppIntentNotification.recordVoice) }; return .result() }
}

struct DictateIntoCurrentAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Dictate Into Current App"
    static let description = IntentDescription("Start or stop local dictation and insert it into the app you were using.")
    static var openAppWhenRun: Bool { true }
    func perform() async throws -> some IntentResult { await MainActor.run { postBELIntent(BELAppIntentNotification.dictate) }; return .result() }
}

struct ReadScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Screen"
    static let description = IntentDescription("Read the current screen locally.")
    static var openAppWhenRun: Bool { true }
    func perform() async throws -> some IntentResult { await MainActor.run { postBELIntent(BELAppIntentNotification.readScreen) }; return .result() }
}

struct WriteQuickNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Write Quick Note"
    static let description = IntentDescription("Open a local quick note in BeLauncher.")
    static var openAppWhenRun: Bool { true }
    func perform() async throws -> some IntentResult { await MainActor.run { postBELIntent(BELAppIntentNotification.quickNote) }; return .result() }
}

struct RecordCallIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Call"
    static let description = IntentDescription("Start or stop explicit local call recording.")
    static var openAppWhenRun: Bool { true }
    func perform() async throws -> some IntentResult { await MainActor.run { postBELIntent(BELAppIntentNotification.recordCall) }; return .result() }
}

struct SearchBrainIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Brain"
    static let description = IntentDescription("Open BeLauncher ready to search your local Brain.")
    static var openAppWhenRun: Bool { true }
    func perform() async throws -> some IntentResult { await MainActor.run { postBELIntent(BELAppIntentNotification.searchBrain) }; return .result() }
}

struct UpcomingMeetingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Upcoming Meetings"
    static let description = IntentDescription("Find upcoming meetings from the local calendar.")
    static var openAppWhenRun: Bool { true }
    func perform() async throws -> some IntentResult { await MainActor.run { postBELIntent(BELAppIntentNotification.upcomingMeetings) }; return .result() }
}

struct StartFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Focus"
    static let description = IntentDescription("Open the BeLauncher focus action for review.")
    static var openAppWhenRun: Bool { true }
    func perform() async throws -> some IntentResult { await MainActor.run { postBELIntent(BELAppIntentNotification.focus) }; return .result() }
}

struct PrepareMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Prepare Meeting"
    static let description = IntentDescription("Open the Brain meeting preparation action.")
    static var openAppWhenRun: Bool { true }
    func perform() async throws -> some IntentResult { await MainActor.run { postBELIntent(BELAppIntentNotification.prepareMeeting) }; return .result() }
}

struct OpenNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Notes"
    static let description = IntentDescription("Open the local Markdown notes surface.")
    static var openAppWhenRun: Bool { true }
    func perform() async throws -> some IntentResult { await MainActor.run { postBELIntent(BELAppIntentNotification.openNotes) }; return .result() }
}

struct OpenGraphIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Brain Graph"
    static let description = IntentDescription("Open the local Brain graph.")
    static var openAppWhenRun: Bool { true }
    func perform() async throws -> some IntentResult { await MainActor.run { postBELIntent(BELAppIntentNotification.openGraph) }; return .result() }
}

struct TranscribeLastVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Review Voice Notes"
    static let description = IntentDescription("Open voice notes that need local transcription review.")
    static var openAppWhenRun: Bool { true }
    func perform() async throws -> some IntentResult { await MainActor.run { postBELIntent(BELAppIntentNotification.transcribeLastVoice) }; return .result() }
}

struct OpenLauncherIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Launcher"
    static let description = IntentDescription("Open BeLauncher's command bar.")
    static var openAppWhenRun: Bool { true }
    func perform() async throws -> some IntentResult { await MainActor.run { postBELIntent(BELAppIntentNotification.openLauncher) }; return .result() }
}

struct BeLauncherShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenBrainIntent(), phrases: ["Open the Brain in \\(.applicationName)"], shortTitle: "Open Brain", systemImageName: "brain")
        AppShortcut(intent: ShowClipboardIntent(), phrases: ["Show clipboard in \\(.applicationName)"], shortTitle: "Clipboard", systemImageName: "doc.on.clipboard")
        AppShortcut(intent: OpenBeLauncherSettingsIntent(), phrases: ["Open \\(.applicationName) settings"], shortTitle: "Settings", systemImageName: "gearshape")
        AppShortcut(intent: RecordVoiceNoteIntent(), phrases: ["Record a voice note in \\(.applicationName)"], shortTitle: "Record voice", systemImageName: "waveform")
        AppShortcut(intent: DictateIntoCurrentAppIntent(), phrases: ["Dictate into the current app with \\(.applicationName)"], shortTitle: "Dictate", systemImageName: "text.cursor")
        AppShortcut(intent: ReadScreenIntent(), phrases: ["Read my screen with \\(.applicationName)"], shortTitle: "Read screen", systemImageName: "rectangle.dashed.and.paperclip")
        AppShortcut(intent: WriteQuickNoteIntent(), phrases: ["Write a quick note in \\(.applicationName)"], shortTitle: "Quick note", systemImageName: "square.and.pencil")
        AppShortcut(intent: RecordCallIntent(), phrases: ["Record a call with \\(.applicationName)"], shortTitle: "Record call", systemImageName: "phone")
        AppShortcut(intent: SearchBrainIntent(), phrases: ["Search my Brain in \\(.applicationName)"], shortTitle: "Search Brain", systemImageName: "magnifyingglass")
        AppShortcut(intent: UpcomingMeetingsIntent(), phrases: ["Show upcoming meetings in \\(.applicationName)"], shortTitle: "Meetings", systemImageName: "calendar")
        AppShortcut(intent: StartFocusIntent(), phrases: ["Start focus in \\(.applicationName)"], shortTitle: "Focus", systemImageName: "scope")
        AppShortcut(intent: PrepareMeetingIntent(), phrases: ["Prepare my meeting in \\(.applicationName)"], shortTitle: "Prepare meeting", systemImageName: "person.2")
        AppShortcut(intent: OpenNotesIntent(), phrases: ["Open my notes in \\(.applicationName)"], shortTitle: "Notes", systemImageName: "note.text")
        AppShortcut(intent: OpenGraphIntent(), phrases: ["Open the Brain graph in \\(.applicationName)"], shortTitle: "Brain graph", systemImageName: "circle.hexagongrid")
        AppShortcut(intent: TranscribeLastVoiceIntent(), phrases: ["Review voice notes in \\(.applicationName)"], shortTitle: "Voice review", systemImageName: "waveform.and.doc")
        AppShortcut(intent: OpenLauncherIntent(), phrases: ["Open \\(.applicationName)"], shortTitle: "Launcher", systemImageName: "command")
    }
}
#endif
