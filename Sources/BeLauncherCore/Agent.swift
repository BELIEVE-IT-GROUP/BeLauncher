import Foundation

/// Commands that are agents, not shortcuts.
///
/// A shortcut does one thing you already described. An agent is told the *outcome* and works out
/// the steps: it looks at what is around, asks for anything it needs permission to touch, shows
/// what it is about to do, does it, and records how it went so the next run is better.
///
/// The six stages are not decoration. They are the difference between an assistant and something
/// that quietly changes your files: every stage is visible, and the two that matter — permission
/// and preview — happen before anything outside the app is touched.
public struct AgentCommand: Sendable, Equatable, Identifiable {

    /// What the agent needs to look at before it can plan anything.
    public enum ContextSource: String, Sendable, Equatable, Codable, CaseIterable {
        case clipboard
        case selection
        case screen
        case calendar
        case brain
        case workGraph
        case files
        case none

        public var label: String {
            switch self {
            case .clipboard: L("what you copied")
            case .selection: L("what you have selected")
            case .screen: L("what is on screen")
            case .calendar: L("your calendar")
            case .brain: L("your brain")
            case .workGraph: L("your work history")
            case .files: L("your files")
            case .none: L("nothing")
            }
        }

        /// The permission macOS demands before this can be read at all.
        public var permission: Onboarding.Capability.Kind? {
            switch self {
            case .calendar: .calendar
            case .selection, .screen: .accessibility
            default: nil
            }
        }
    }

    public enum Stage: String, Sendable, Equatable, Codable, CaseIterable {
        case inspecting
        case awaitingPermission
        case planning
        case awaitingApproval
        case executing
        case learning
        case done
        case failed
        case cancelled

        public var label: String {
            switch self {
            case .inspecting: L("Looking at the context")
            case .awaitingPermission: L("A permission is missing")
            case .planning: L("Working out the plan")
            case .awaitingApproval: L("Waiting for your go-ahead")
            case .executing: "Ejecutando"
            case .learning: L("Keeping what it learned")
            case .done: L("Done")
            case .failed: L("Failed")
            case .cancelled: "Cancelado"
            }
        }

        public var isFinished: Bool {
            self == .done || self == .failed || self == .cancelled
        }

        /// Whether the person has to do something before this can move on.
        public var waitsForPerson: Bool {
            self == .awaitingPermission || self == .awaitingApproval
        }
    }

    public let id: String
    /// What you type after the slash: `/research`, `/followup`.
    public let verb: String
    public let title: String
    /// Written for the person, not for the log.
    public let summary: String
    public let reads: [ContextSource]
    /// Whether the argument is required, and what to call it when asking for one.
    public let argument: String?
    public let symbol: String
    /// Whether the outcome shows as a canvas of editable blocks rather than a plain result.
    public let opensCanvas: Bool

    public init(id: String, verb: String, title: String, summary: String,
                reads: [ContextSource], argument: String? = nil, symbol: String = "sparkles",
                opensCanvas: Bool = false) {
        self.id = id
        self.verb = verb
        self.title = title
        self.summary = summary
        self.reads = reads
        self.argument = argument
        self.symbol = symbol
        self.opensCanvas = opensCanvas
    }

    /// The permissions this command needs, in the order it will need them.
    public var requiredPermissions: [Onboarding.Capability.Kind] {
        var seen: Set<String> = []
        return reads.compactMap(\.permission).filter { seen.insert($0.rawValue).inserted }
    }

    // MARK: - Parsing

    /// Slash commands, because that is what people already type everywhere else.
    ///
    /// The leading slash is what makes this unambiguous: a launcher whose search box also runs
    /// agents has to be able to tell "research" the search from "/research" the instruction, and
    /// guessing from the words is how you end up firing an agent because somebody typed a noun.
    public static func parse(_ query: String, in commands: [AgentCommand])
        -> (command: AgentCommand, argument: String)?
    {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return nil }

        let body = String(trimmed.dropFirst())
        let folded = body.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                  locale: .current)
        guard let verb = folded.split(separator: " ").first.map(String.init) else { return nil }
        guard let command = commands.first(where: { $0.verb == verb }) else { return nil }

        let argument = String(body.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
        return (command, argument)
    }

    /// Commands matching what has been typed so far, so the slash menu can complete.
    public static func suggestions(for query: String, in commands: [AgentCommand]) -> [AgentCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return [] }
        let typed = String(trimmed.dropFirst())
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard !typed.contains(" ") else { return [] }
        return commands
            .filter { typed.isEmpty || $0.verb.hasPrefix(typed) }
            .sorted { $0.verb < $1.verb }
    }
}

/// One run of one agent command, from typed to finished.
///
/// Held as data rather than as a closure chain so the whole thing is inspectable: at any moment the
/// person can see which stage it is in, what it looked at, what it wants to do and what it has
/// already done. An agent whose progress you cannot read is one you have to trust blindly.
public struct AgentRun: Sendable, Equatable, Identifiable {

    public struct Finding: Sendable, Equatable, Identifiable {
        public let id: String
        public let source: AgentCommand.ContextSource
        public let summary: String

        public init(id: String = UUID().uuidString, source: AgentCommand.ContextSource,
                    summary: String) {
            self.id = id
            self.source = source
            self.summary = summary
        }
    }

    public var id: String
    public let command: AgentCommand
    public let argument: String
    public var stage: AgentCommand.Stage
    /// What it read, and what it found there.
    public var findings: [Finding]
    /// The permission it is stuck on, when it is stuck on one.
    public var missingPermission: Onboarding.Capability.Kind?
    public var plan: [PlannedStep]
    public var canvas: Canvas?
    public var result: String
    public var failure: String?
    public let startedAt: Date
    public var finishedAt: Date?
    /// Roughly what this cost, when a paid model was involved. Nil means nothing was spent.
    public var tokensUsed: Int?

    public init(id: String = UUID().uuidString, command: AgentCommand, argument: String,
                stage: AgentCommand.Stage = .inspecting, findings: [Finding] = [],
                missingPermission: Onboarding.Capability.Kind? = nil, plan: [PlannedStep] = [],
                canvas: Canvas? = nil, result: String = "", failure: String? = nil,
                startedAt: Date = .now, finishedAt: Date? = nil, tokensUsed: Int? = nil) {
        self.id = id
        self.command = command
        self.argument = argument
        self.stage = stage
        self.findings = findings
        self.missingPermission = missingPermission
        self.plan = plan
        self.canvas = canvas
        self.result = result
        self.failure = failure
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.tokensUsed = tokensUsed
    }

    public var title: String {
        argument.isEmpty ? command.title : "\(command.title): \(argument)"
    }

    /// Whether anything in the plan reaches outside the app. Nothing runs unapproved when it does.
    public var changesSomething: Bool {
        plan.contains { $0.action.changesSomething }
    }

    /// What to show in the tray, in one line, whatever stage it is in.
    public var status: String {
        switch stage {
        case .awaitingPermission:
            L("It needs a permission: %@", missingPermission?.rawValue ?? L("unknown"))
        case .failed:
            failure ?? L("Failed")
        case .done:
            result.isEmpty ? L("Done") : String(result.prefix(70))
        default:
            stage.label
        }
    }
}

/// Drives a run through its stages. Pure: it decides the next stage, it never performs anything.
///
/// Splitting the decision from the doing is what makes an agent testable. Every "what should happen
/// next" question is answered here against plain values, and the app layer is left with nothing but
/// carrying out actions it was handed.
public enum AgentDriver {

    /// The stage after inspecting: blocked on a permission, or ready to plan.
    public static func afterInspecting(
        _ run: AgentRun, granted: (Onboarding.Capability.Kind) -> Bool
    ) -> AgentRun {
        var next = run
        if let missing = run.command.requiredPermissions.first(where: { !granted($0) }) {
            next.stage = .awaitingPermission
            next.missingPermission = missing
            return next
        }
        next.missingPermission = nil
        next.stage = .planning
        return next
    }

    /// The stage after planning: nothing to do, needs approval, or safe to run.
    public static func afterPlanning(_ run: AgentRun) -> AgentRun {
        var next = run
        guard !run.plan.isEmpty || run.canvas != nil else {
            next.stage = .failed
            next.failure = L("I could not think of anything to do with that. Better to say so than to make something up.")
            next.finishedAt = .now
            return next
        }
        // A canvas is a proposal by definition: it is shown, never carried out on its own.
        next.stage = run.canvas != nil || run.changesSomething ? .awaitingApproval : .executing
        return next
    }

    public static func approve(_ run: AgentRun) -> AgentRun {
        var next = run
        guard run.stage == .awaitingApproval else { return run }
        next.stage = .executing
        return next
    }

    public static func cancel(_ run: AgentRun) -> AgentRun {
        var next = run
        guard !run.stage.isFinished else { return run }
        next.stage = .cancelled
        next.finishedAt = .now
        return next
    }

    public static func finish(_ run: AgentRun, result: String, tokensUsed: Int? = nil) -> AgentRun {
        var next = run
        next.stage = .done
        next.result = result
        next.tokensUsed = tokensUsed
        next.finishedAt = .now
        return next
    }

    public static func fail(_ run: AgentRun, _ reason: String) -> AgentRun {
        var next = run
        next.stage = .failed
        next.failure = reason
        next.finishedAt = .now
        return next
    }

    /// What the run teaches. Only ever the shape of the work, never its contents: that a proposal
    /// was accepted, not what the proposal said.
    public static func lesson(from run: AgentRun) -> (trait: String, value: String)? {
        guard run.stage == .done else { return nil }
        return ("agent.\(run.command.id).accepted", "1")
    }
}
