#if canImport(AppIntents)
import AppIntents
import Foundation
import BeLauncherCore

enum BELAppIntentNotification {
    static let runCommand = Notification.Name("com.believe.belauncher.intent.runCommand")
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

enum BELAppIntentUserInfo {
    static let actionID = "actionID"
    static let command = "command"
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

private func runCuratedIntent(_ definition: BELAppIntentDefinition, command: String? = nil) {
    let resolved = command ?? definition.command
    guard !resolved.isEmpty else { return }
    NotificationCenter.default.post(
        name: BELAppIntentNotification.runCommand,
        object: nil,
        userInfo: [BELAppIntentUserInfo.actionID: definition.id,
                   BELAppIntentUserInfo.command: resolved]
    )
}

private protocol BELCuratedIntent: AppIntent {
    static var catalogID: String { get }
}

extension BELCuratedIntent {
    static var definition: BELAppIntentDefinition { BELAppIntentCatalog.definition(id: catalogID)! }
    static var openAppWhenRun: Bool { true }
}

struct SummarizeClipboardIntent: BELCuratedIntent {
    static let catalogID = "clipboard.summarize"
    static let title: LocalizedStringResource = "Summarize Clipboard"
    static let description = IntentDescription("Open BeLauncher with the clipboard ready to summarize.")
    func perform() async throws -> some IntentResult { await MainActor.run { runCuratedIntent(Self.definition) }; return .result() }
}

struct RewriteClipboardIntent: BELCuratedIntent {
    static let catalogID = "clipboard.rewrite"
    static let title: LocalizedStringResource = "Rewrite Clipboard"
    static let description = IntentDescription("Open BeLauncher with the clipboard ready to rewrite.")
    func perform() async throws -> some IntentResult { await MainActor.run { runCuratedIntent(Self.definition) }; return .result() }
}

struct TranslateClipboardIntent: BELCuratedIntent {
    static let catalogID = "clipboard.translate"
    static let title: LocalizedStringResource = "Translate Clipboard"
    static let description = IntentDescription("Open BeLauncher with the clipboard ready to translate.")
    func perform() async throws -> some IntentResult { await MainActor.run { runCuratedIntent(Self.definition) }; return .result() }
}

struct AskAboutClipboardIntent: BELCuratedIntent {
    static let catalogID = "clipboard.ask"
    static let title: LocalizedStringResource = "Ask About Clipboard"
    static let description = IntentDescription("Open BeLauncher to ask your Brain about the clipboard.")
    @Parameter(title: "Question") var question: String
    init() { question = "" }
    func perform() async throws -> some IntentResult {
        await MainActor.run { runCuratedIntent(Self.definition, command: question.isEmpty ? nil : "ask about clipboard \(question)") }
        return .result()
    }
}

struct SummarizeSelectedFileIntent: BELCuratedIntent {
    static let catalogID = "file.summarize"
    static let title: LocalizedStringResource = "Summarize Selected File"
    static let description = IntentDescription("Open BeLauncher to review a file summary.")
    func perform() async throws -> some IntentResult { await MainActor.run { runCuratedIntent(Self.definition) }; return .result() }
}

struct AskAboutSelectedFileIntent: BELCuratedIntent {
    static let catalogID = "file.ask"
    static let title: LocalizedStringResource = "Ask About Selected File"
    static let description = IntentDescription("Open BeLauncher to review questions about a file.")
    func perform() async throws -> some IntentResult { await MainActor.run { runCuratedIntent(Self.definition) }; return .result() }
}

struct SmartRenameSelectedFileIntent: BELCuratedIntent {
    static let catalogID = "file.rename"
    static let title: LocalizedStringResource = "Smart Rename Selected File"
    static let description = IntentDescription("Open BeLauncher to review a proposed file rename.")
    func perform() async throws -> some IntentResult { await MainActor.run { runCuratedIntent(Self.definition) }; return .result() }
}

struct DraftEmailIntent: BELCuratedIntent {
    static let catalogID = "email.draft"
    static let title: LocalizedStringResource = "Draft Email"
    static let description = IntentDescription("Open BeLauncher to review an email draft.")
    func perform() async throws -> some IntentResult { await MainActor.run { runCuratedIntent(Self.definition) }; return .result() }
}

struct ReplyInMyVoiceIntent: BELCuratedIntent {
    static let catalogID = "email.reply"
    static let title: LocalizedStringResource = "Reply in My Voice"
    static let description = IntentDescription("Open BeLauncher to review a reply in your voice.")
    func perform() async throws -> some IntentResult { await MainActor.run { runCuratedIntent(Self.definition) }; return .result() }
}

struct CreateTasksFromClipboardIntent: BELCuratedIntent {
    static let catalogID = "clipboard.tasks"
    static let title: LocalizedStringResource = "Create Tasks from Clipboard"
    static let description = IntentDescription("Open BeLauncher with tasks extracted from the clipboard for review.")
    func perform() async throws -> some IntentResult { await MainActor.run { runCuratedIntent(Self.definition) }; return .result() }
}

struct PlanMyDayIntent: BELCuratedIntent {
    static let catalogID = "day.plan"
    static let title: LocalizedStringResource = "Plan My Day"
    static let description = IntentDescription("Open BeLauncher to review a plan for today.")
    func perform() async throws -> some IntentResult { await MainActor.run { runCuratedIntent(Self.definition) }; return .result() }
}

struct PreMeetingBriefIntent: BELCuratedIntent {
    static let catalogID = "meeting.brief"
    static let title: LocalizedStringResource = "Pre-Meeting Brief"
    static let description = IntentDescription("Open BeLauncher with the local meeting preparation action.")
    func perform() async throws -> some IntentResult { await MainActor.run { runCuratedIntent(Self.definition) }; return .result() }
}

struct QuickResearchIntent: BELCuratedIntent {
    static let catalogID = "research.quick"
    static let title: LocalizedStringResource = "Quick Research"
    static let description = IntentDescription("Open BeLauncher to review a research request.")
    func perform() async throws -> some IntentResult { await MainActor.run { runCuratedIntent(Self.definition) }; return .result() }
}

struct SaveToBeBrainIntent: BELCuratedIntent {
    static let catalogID = "brain.save"
    static let title: LocalizedStringResource = "Save to Be Brain"
    static let description = IntentDescription("Open BeLauncher to review what will be saved to your local Brain.")
    func perform() async throws -> some IntentResult { await MainActor.run { runCuratedIntent(Self.definition) }; return .result() }
}

struct RecallFromBeBrainIntent: BELCuratedIntent {
    static let catalogID = "brain.recall"
    static let title: LocalizedStringResource = "Recall from Be Brain"
    static let description = IntentDescription("Open BeLauncher ready to search your local Brain.")
    func perform() async throws -> some IntentResult { await MainActor.run { runCuratedIntent(Self.definition) }; return .result() }
}

struct RunBeLauncherCommandIntent: BELCuratedIntent {
    static let catalogID = "launcher.command"
    static let title: LocalizedStringResource = "Run BeLauncher Command"
    static let description = IntentDescription("Open BeLauncher with a command for review and execution.")
    @Parameter(title: "Command") var command: String
    init() { command = "" }
    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$command)") }
    func perform() async throws -> some IntentResult {
        await MainActor.run { runCuratedIntent(Self.definition, command: command) }
        return .result()
    }
}

struct BeLauncherShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SummarizeClipboardIntent(), phrases: ["Summarize my clipboard in \\(.applicationName)"], shortTitle: "Summarize clipboard", systemImageName: "text.quote")
        AppShortcut(intent: RewriteClipboardIntent(), phrases: ["Rewrite my clipboard in \\(.applicationName)"], shortTitle: "Rewrite clipboard", systemImageName: "pencil")
        AppShortcut(intent: TranslateClipboardIntent(), phrases: ["Translate my clipboard in \\(.applicationName)"], shortTitle: "Translate clipboard", systemImageName: "character.bubble")
        AppShortcut(intent: AskAboutClipboardIntent(), phrases: ["Ask about my clipboard in \\(.applicationName)"], shortTitle: "Ask about clipboard", systemImageName: "questionmark.bubble")
        AppShortcut(intent: SummarizeSelectedFileIntent(), phrases: ["Summarize the selected file in \\(.applicationName)"], shortTitle: "Summarize file", systemImageName: "doc.text")
        AppShortcut(intent: AskAboutSelectedFileIntent(), phrases: ["Ask about the selected file in \\(.applicationName)"], shortTitle: "Ask about file", systemImageName: "doc.questionmark")
        AppShortcut(intent: SmartRenameSelectedFileIntent(), phrases: ["Rename the selected file with \\(.applicationName)"], shortTitle: "Rename file", systemImageName: "pencil.and.list.clipboard")
        AppShortcut(intent: DraftEmailIntent(), phrases: ["Draft an email in \\(.applicationName)"], shortTitle: "Draft email", systemImageName: "envelope")
        AppShortcut(intent: ReplyInMyVoiceIntent(), phrases: ["Reply in my voice with \\(.applicationName)"], shortTitle: "Reply in my voice", systemImageName: "arrowshape.turn.up.left")
        AppShortcut(intent: CreateTasksFromClipboardIntent(), phrases: ["Create tasks from my clipboard in \\(.applicationName)"], shortTitle: "Create tasks", systemImageName: "checklist")
        AppShortcut(intent: PlanMyDayIntent(), phrases: ["Plan my day in \\(.applicationName)"], shortTitle: "Plan my day", systemImageName: "sun.max")
        AppShortcut(intent: PreMeetingBriefIntent(), phrases: ["Prepare my meeting in \\(.applicationName)"], shortTitle: "Meeting brief", systemImageName: "person.2")
        AppShortcut(intent: QuickResearchIntent(), phrases: ["Research this in \\(.applicationName)"], shortTitle: "Quick research", systemImageName: "safari")
        AppShortcut(intent: SaveToBeBrainIntent(), phrases: ["Save this to Be Brain in \\(.applicationName)"], shortTitle: "Save to Brain", systemImageName: "brain")
        AppShortcut(intent: RecallFromBeBrainIntent(), phrases: ["Recall from Be Brain in \\(.applicationName)"], shortTitle: "Recall from Brain", systemImageName: "magnifyingglass")
        AppShortcut(intent: RunBeLauncherCommandIntent(), phrases: ["Run a command in \\(.applicationName)"], shortTitle: "Run command", systemImageName: "command")
    }
}
#endif
