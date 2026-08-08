import Foundation

/// Intent, executed: you say what you want, the app works out the steps, shows them, and only
/// then does anything.
///
/// The trust model is the feature, not a wrapper around it. Every mission has a plan you can read
/// before it runs, a receipt of what it actually did, and an undo where undoing is possible. An
/// agent that acts on your Mac without those three is a demo, not a product.
public struct Mission: Sendable, Equatable, Identifiable, Codable {

    public enum State: String, Sendable, Equatable, Codable {
        case planning
        /// Waiting for the person to approve the plan.
        case awaitingApproval
        case running
        case done
        case failed
        case cancelled
    }

    public var id: String
    public var intent: String
    public var state: State
    public var steps: [PlannedStep]
    public var createdAt: Date
    public var finishedAt: Date?
    public var failure: String?

    public init(id: String = UUID().uuidString, intent: String, state: State = .planning,
                steps: [PlannedStep] = [], createdAt: Date = .now, finishedAt: Date? = nil,
                failure: String? = nil) {
        self.id = id
        self.intent = intent
        self.state = state
        self.steps = steps
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.failure = failure
    }

    /// A mission needs approval when any step changes something outside the app.
    public var needsApproval: Bool {
        steps.contains { $0.action.changesSomething }
    }

    public var summary: String {
        steps.map(\.title).joined(separator: " → ")
    }
}

public struct PlannedStep: Sendable, Equatable, Identifiable, Codable {
    public enum Outcome: String, Sendable, Equatable, Codable {
        case pending
        case done
        case skipped
        case failed
    }

    public var id: String
    public var title: String
    public var action: LauncherModel.Action
    public var outcome: Outcome
    public var detail: String

    public init(id: String = UUID().uuidString, title: String, action: LauncherModel.Action,
                outcome: Outcome = .pending, detail: String = "") {
        self.id = id
        self.title = title
        self.action = action
        self.outcome = outcome
        self.detail = detail
    }
}

extension LauncherModel.Action {
    /// Whether carrying this out changes something the user would notice afterwards. Anything
    /// that does forces a mission to ask first.
    public var changesSomething: Bool {
        switch self {
        case .copyToClipboard, .openURL, .openFile, .revealInFinder, .launchApplication,
             .quickLook, .openWith, .dismiss, .wait, .openSettings, .runVerb, .openCanvas,
             .runAgent:
            // An agent asks before it touches anything; handing it the job changes nothing yet.
            // A canvas is a proposal on screen. Nothing outside the app moves until the person
            // runs one of its blocks.
            return false
        case .moveToTrash, .systemCommand, .runShortcut, .startTimer, .arrangeWindow,
             .remember, .confirmCommit, .discardCommit, .runFlow, .assignAlias, .runMission,
             .quitProcess, .forceQuit, .stayAwake, .writeNote, .createSnippet, .openQuickNoteEditor,
             .saveWorkspace, .restoreWorkspace:
            return true
        case .missionCancelled, .cancelAI:
            return false
        }
    }

    /// What a receipt says this step did.
    public var receiptLine: String {
        switch self {
        case .launchApplication(let path): L("Open %@", (path as NSString).lastPathComponent)
        case .openURL(let url): L("Open %@", url.host() ?? url.absoluteString)
        case .openFile(let path): L("Open %@", (path as NSString).lastPathComponent)
        case .revealInFinder(let path): "Mostrar \((path as NSString).lastPathComponent)"
        case .copyToClipboard(let text, _): "Copiar \(text.count) caracteres"
        case .moveToTrash(let path): L("Move %@ to the trash", (path as NSString).lastPathComponent)
        case .systemCommand(let kind): L("System command: %@", String(describing: kind))
        case .runShortcut(let name): L("Run the shortcut “%@”", name)
        case .startTimer(let minutes, _): L("A %@ min timer", String(minutes))
        case .arrangeWindow(let layout): L("Place the window: %@", String(describing: layout))
        case .remember(let text, _): "Proponer memoria: \(text.prefix(40))"
        case .confirmCommit: L("Confirm a memory")
        case .discardCommit: L("Discard a proposal")
        case .runFlow(let steps): L("Run a flow of %@ steps", String(steps.count))
        case .runVerb(let id, _): L("Ask the AI: %@", id)
        case .quickLook: L("Quick Look")
        case .openWith: L("Open with another app")
        case .openSettings: L("Open settings")
        case .wait(let seconds): "Esperar \(Int(seconds))s"
        case .assignAlias(_, let suggestion): L("Give %@ an alias", suggestion)
        case .runMission(let mission): L("Run the mission “%@”", mission.intent)
        case .missionCancelled: L("Mission cancelled")
        case .cancelAI: L("Request cancelled")
        case .quitProcess(let pid): L("Close process %@", String(pid))
        case .forceQuit(let pid): L("Force process %@ to quit", String(pid))
        case .stayAwake(let minutes):
            minutes.map { "Mantener despierto \($0) min" } ?? "Mantener despierto"
        case .writeNote(let text): L("Keep a note: %@", String(text.prefix(40)))
        case .openQuickNoteEditor(let text): L("Open note editor: %@", String(text.prefix(40)))
        case .createSnippet(let text): L("Create a snippet: %@", String(text.prefix(40)))
        case .saveWorkspace(let name): L("Save the window layout “%@”", name)
        case .restoreWorkspace(let name): L("Place the layout “%@”", name)
        case .openCanvas(_, let brief): L("Open a canvas: %@", String(brief.prefix(40)))
        case .runAgent(let id, _): L("Commission “%@”", id)
        case .dismiss: L("Close the window")
        }
    }
}

/// What a mission actually did, written after the fact.
///
/// Boring until it prevents a disaster, and then it is the reason people trust the thing. It says
/// what was asked, what ran, what changed and what can be undone — never a summary written by the
/// same model that did the work.
public struct MissionReceipt: Sendable, Equatable {
    public let missionID: String
    public let intent: String
    public let requestedBy: String
    public let startedAt: Date
    public let finishedAt: Date
    public let lines: [String]
    public let changed: [String]
    public let undoable: [String]

    public init(missionID: String, intent: String, requestedBy: String, startedAt: Date,
                finishedAt: Date, lines: [String], changed: [String], undoable: [String]) {
        self.missionID = missionID
        self.intent = intent
        self.requestedBy = requestedBy
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.lines = lines
        self.changed = changed
        self.undoable = undoable
    }

    public static func of(_ mission: Mission, requestedBy: String) -> MissionReceipt {
        let done = mission.steps.filter { $0.outcome == .done }
        return MissionReceipt(
            missionID: mission.id,
            intent: mission.intent,
            requestedBy: requestedBy,
            startedAt: mission.createdAt,
            finishedAt: mission.finishedAt ?? .now,
            lines: mission.steps.map { step in
                "\(symbol(step.outcome)) \(step.title)"
                    + (step.detail.isEmpty ? "" : " — \(step.detail)")
            },
            changed: done.filter { $0.action.changesSomething }.map { $0.action.receiptLine },
            undoable: done.compactMap { step in
                if case .moveToTrash(let path) = step.action {
                    return L("Get %@ back out of the trash", (path as NSString).lastPathComponent)
                }
                if case .confirmCommit = step.action { return L("Undo the confirmed memory") }
                return nil
            }
        )
    }

    static func symbol(_ outcome: PlannedStep.Outcome) -> String {
        switch outcome {
        case .pending: "·"
        case .done: "✓"
        case .skipped: "–"
        case .failed: "✗"
        }
    }

    public func render() -> String {
        var text = ["# \(intent)", "", "Pedido por \(requestedBy)", ""]
        text += lines
        if !changed.isEmpty {
            text += ["", L("Changed:")] + changed.map { "- \($0)" }
        }
        if !undoable.isEmpty {
            text += ["", "Se puede deshacer:"] + undoable.map { "- \($0)" }
        }
        return text.joined(separator: "\n")
    }

    /// Turns the execution receipt into the fourth level of truth. The stable mission link makes
    /// reruns idempotent in the Vault and lets the reader walk from result back to evidence.
    public func outcomeMemory() -> MemoryObject {
        MemoryObject(
            id: "outcome-\(missionID)",
            level: .outcome,
            kind: .learning,
            statement: L("Mission outcome: %@", intent),
            body: render(),
            source: "mission:\(missionID)",
            owner: requestedBy,
            createdAt: finishedAt,
            validFrom: finishedAt,
            evidence: ["mission:\(missionID)"]
        )
    }
}

/// Turns an intent into a plan, from a closed catalogue of outcomes.
///
/// Five things done well rather than a universal agent done badly. Each outcome is a named recipe
/// the app knows how to carry out; the model, when there is one, only fills in the blanks.
public enum MissionPlanner {

    public struct Outcome: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let triggers: [String]
        public let describe: @Sendable (String) -> String

        public static func == (lhs: Outcome, rhs: Outcome) -> Bool { lhs.id == rhs.id }

        public init(id: String, title: String, triggers: [String],
                    describe: @escaping @Sendable (String) -> String) {
            self.id = id
            self.title = title
            self.triggers = triggers
            self.describe = describe
        }
    }

    /// What the app knows how to get done.
    ///
    /// Every one of these is an *outcome*, phrased the way someone would say it out loud, never the
    /// name of a tool. "Organiza mis descargas", not "abre Finder". The catalogue is closed on
    /// purpose: nine things it does properly beats a universal agent that produces something
    /// plausible for anything and something useful for nothing.
    /// Computed rather than stored so a language chosen after launch reaches these titles. The
    /// **triggers stay bilingual whatever the interface says** — somebody who switched the menu bar
    /// to English and still types "enfoque" is not making a mistake, and losing a mission they use
    /// every morning is not an acceptable price for a language setting.
    public static var outcomes: [Outcome] {
        [
            .init(id: "focus", title: L("Get me working"),
                  triggers: ["focus", "get me working", "deep work",
                             "enfoque", "concentrar", "ponerme a trabajar"],
                  describe: { _ in L("Silences everything, opens your things and starts a block of work.") }),
            .init(id: "close-day", title: L("Close the day"),
                  triggers: ["close my day", "close the day", "wrap up",
                             "cerrar el dia", "cerrar dia"],
                  describe: { _ in L("Goes over what is left and keeps what you learned.") }),
            .init(id: "capture-meeting", title: L("Turn notes into memory"),
                  triggers: ["capture meeting", "save notes", "save my notes",
                             "guardar notas", "capturar reunion"],
                  describe: { _ in L("Pulls decisions and commitments out of your notes and proposes them.") }),
            .init(id: "tidy-downloads", title: L("Tidy up Downloads"),
                  triggers: ["tidy downloads", "clean downloads", "sort my downloads",
                             "ordenar descargas", "limpiar descargas", "organiza mis descargas"],
                  describe: { _ in L("Shows you what is in there and lets you move it or bin it.") }),
            .init(id: "make-proposal", title: L("Turn this into a proposal"),
                  triggers: ["make a proposal", "turn this into a proposal", "write a proposal",
                             "convierte esto en una propuesta", "haz una propuesta",
                             "convertir en propuesta"],
                  describe: { subject in
                      subject.isEmpty
                          ? L("Builds the proposal from whatever you have copied.")
                          : L("Builds the proposal for %@.", subject)
                  }),
            .init(id: "answer-urgent", title: L("Answer what is urgent"),
                  triggers: ["answer what is urgent", "what is urgent", "whats urgent",
                             "responde lo urgente", "responder lo urgente", "que es urgente"],
                  describe: { _ in L("Looks at what is overdue or nearly due and tells you where to start.") }),
            .init(id: "publish-idea", title: L("Publish this idea"),
                  triggers: ["publish this", "publish this idea",
                             "publica esta idea", "publicar esta idea"],
                  describe: { _ in L("Turns the note into something publishable and leaves it copied.") }),
            .init(id: "clean-desktop", title: L("Clear the desktop"),
                  triggers: ["clean desktop", "clear the desktop", "tidy my desktop",
                             "limpia el escritorio", "limpiar escritorio"],
                  describe: { _ in L("Opens the desktop so you can see what is in the way.") }),
            .init(id: "start-week", title: L("Start the week"),
                  triggers: ["start my week", "start the week",
                             "arrancar la semana", "empezar la semana"],
                  describe: { _ in L("Goes over open commitments and whatever is going stale.") }),
        ]
    }

    public static func outcome(for intent: String) -> (outcome: Outcome, argument: String)? {
        let folded = Phrases.fold(intent)
        for outcome in outcomes {
            for trigger in outcome.triggers where folded.contains(trigger) {
                let argument = folded
                    .replacingOccurrences(of: trigger, with: "")
                    .trimmingCharacters(in: .whitespaces)
                return (outcome, argument)
            }
        }
        return nil
    }

    /// Builds the plan for an intent. Returns nil when nothing in the catalogue fits, which is
    /// the honest answer: better no mission than a made-up one.
    public static func plan(_ intent: String, clipboard: String = "") -> Mission? {
        guard let (outcome, argument) = outcome(for: intent) else { return nil }

        var steps: [PlannedStep] = []
        switch outcome.id {
        case "focus":
            steps = [
                .init(title: L("Turn on Do Not Disturb"),
                      action: .systemCommand(SystemCommand.Kind.toggleDoNotDisturb.rawValue)),
                .init(title: L("50-minute timer"),
                      action: .startTimer(minutes: 50, label: L("Focus block"))),
            ]

        case "close-day":
            steps = [
                .init(title: L("Pull out what is left today"),
                      action: .runVerb(id: "extract-tasks", text: clipboard)),
                .init(title: L("Propose it as a memory"),
                      action: .remember(text: clipboard, source: L("End of day"))),
            ]

        case "capture-meeting":
            steps = [
                .init(title: L("Pull out decisions and commitments"),
                      action: .runVerb(id: "extract-tasks", text: clipboard)),
                .init(title: L("Propose them to the brain"),
                      action: .remember(text: clipboard, source: L("Meeting notes"))),
            ]

        case "tidy-downloads":
            steps = [
                .init(title: L("Open Downloads"),
                      action: .systemCommand(SystemCommand.Kind.openDownloads.rawValue)),
            ]

        case "make-proposal":
            // A proposal is not one answer, it is six pieces, so this opens a canvas rather than
            // producing a wall of text nobody can edit piece by piece.
            steps = [
                .init(title: L("Build the proposal"),
                      action: .openCanvas(template: "proposal", brief: argument.isEmpty
                          ? clipboard : argument)),
            ]

        case "answer-urgent":
            steps = [
                .init(title: L("Look at what is overdue or nearly due"),
                      action: .runVerb(id: "extract-tasks", text: clipboard)),
            ]

        case "publish-idea":
            steps = [
                .init(title: L("Turn it into something publishable"),
                      action: .runVerb(id: "publish", text: clipboard)),
            ]

        case "clean-desktop":
            steps = [
                .init(title: L("Open the desktop"),
                      action: .systemCommand(SystemCommand.Kind.openDesktop.rawValue)),
            ]

        case "start-week":
            steps = [
                .init(title: L("Go over what is going stale"),
                      action: .runVerb(id: "week-review", text: clipboard)),
            ]

        default:
            return nil
        }

        return Mission(intent: intent,
                       state: steps.contains { $0.action.changesSomething } ? .awaitingApproval : .running,
                       steps: steps)
    }
}
