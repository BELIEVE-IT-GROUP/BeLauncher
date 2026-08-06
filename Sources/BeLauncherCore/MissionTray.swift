import Foundation

/// Work that keeps going while you get on with something else.
///
/// "Investiga cinco alternativas a HubSpot y déjame una comparación" cannot be a modal spinner: it
/// takes minutes, and a launcher that blocks for minutes is worse than no launcher. So a request
/// like that becomes a mission in a tray — visible, interruptible, and never quietly finished.
///
/// The reason this is not just "run it in the background" is trust. An agent with access to your
/// files that works out of sight is the single scariest thing in this product. Every mission
/// therefore carries the same six things, always, and the tray shows them: the plan, where it got
/// its information, what it actually did, what it cost, what permissions it used, and what can be
/// undone. Anything that cannot produce those six does not get to run unattended.
public struct TrayMission: Sendable, Equatable, Identifiable {

    public enum State: String, Sendable, Equatable, Codable, CaseIterable {
        case preparing
        case awaitingPermission
        case needsDecision
        case working
        case completed
        case failed
        case cancelled

        public var label: String {
            switch self {
            case .preparing: "Preparando"
            case .awaitingPermission: L("A permission is missing")
            case .needsDecision: L("It needs you to decide")
            case .working: "Trabajando"
            case .completed: "Terminado"
            case .failed: L("Failed")
            case .cancelled: "Cancelado"
            }
        }

        public var symbol: String {
            switch self {
            case .preparing: "hourglass"
            case .awaitingPermission: "lock"
            case .needsDecision: "questionmark.circle"
            case .working: "gearshape.arrow.trianglehead.2.clockwise.rotate.90"
            case .completed: "checkmark.circle.fill"
            case .failed: "exclamationmark.triangle.fill"
            case .cancelled: "xmark.circle"
            }
        }

        public var isFinished: Bool {
            self == .completed || self == .failed || self == .cancelled
        }

        /// Whether it is stuck until the person does something. These are the ones the tray badge
        /// counts: a mission quietly working needs no attention, one waiting on you does.
        public var needsYou: Bool {
            self == .awaitingPermission || self == .needsDecision
        }
    }

    /// Where a piece of the answer came from, so a conclusion can be checked rather than believed.
    public struct Source: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let detail: String

        public init(id: String = UUID().uuidString, title: String, detail: String = "") {
            self.id = id
            self.title = title
            self.detail = detail
        }
    }

    public var id: String
    public let intent: String
    public var state: State
    public var plan: [PlannedStep]
    public var sources: [Source]
    /// What actually happened, appended as it happens.
    public var performed: [String]
    /// Approximate tokens spent. Zero for anything run on a local model.
    public var tokensUsed: Int
    /// Permissions this mission actually used, named so the receipt is checkable.
    public var permissionsUsed: [String]
    public var result: String
    public var failure: String?
    /// What the person is being asked, when the state is `needsDecision`.
    public var question: String?
    public var undoable: [UndoableStep]
    public let startedAt: Date
    public var finishedAt: Date?

    public init(id: String = UUID().uuidString, intent: String, state: State = .preparing,
                plan: [PlannedStep] = [], sources: [Source] = [], performed: [String] = [],
                tokensUsed: Int = 0, permissionsUsed: [String] = [], result: String = "",
                failure: String? = nil, question: String? = nil, undoable: [UndoableStep] = [],
                startedAt: Date = .now, finishedAt: Date? = nil) {
        self.id = id
        self.intent = intent
        self.state = state
        self.plan = plan
        self.sources = sources
        self.performed = performed
        self.tokensUsed = tokensUsed
        self.permissionsUsed = permissionsUsed
        self.result = result
        self.failure = failure
        self.question = question
        self.undoable = undoable
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// The receipt, assembled from what happened rather than written by whatever did it.
    public func receipt() -> String {
        var lines = ["# \(intent)", "", "Estado: \(state.label)"]
        if !plan.isEmpty {
            lines += ["", "## Plan"] + plan.map { "- \($0.title)" }
        }
        if !sources.isEmpty {
            lines += ["", L("## Where it came from")] + sources.map { "- \($0.title) \($0.detail)" }
        }
        if !performed.isEmpty {
            lines += ["", L("## What it did")] + performed.map { "- \($0)" }
        }
        lines += ["", L("## Cost"), tokensUsed == 0
            ? L("Nothing: it was done with a local model.")
            : L("≈%@ tokens from your provider.", String(tokensUsed))]
        if !permissionsUsed.isEmpty {
            lines += ["", L("## Permissions used")] + permissionsUsed.map { "- \($0)" }
        }
        if !undoable.isEmpty {
            lines += ["", L("## Can be undone")] + undoable.map { "- \($0.label)" }
        }
        if !result.isEmpty {
            lines += ["", L("## Result"), result]
        }
        return lines.joined(separator: "\n")
    }
}

/// Something a mission did that can be put back.
///
/// Modelled as data instead of a closure so the offer survives the mission ending, the window
/// closing and the app restarting. An undo button that only works while the sheet is open is a
/// decoration.
public struct UndoableStep: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case restoreFromTrash
        case revertMemory
        case removeCreatedFile
        case restoreClipboard
    }

    public let id: String
    public let kind: Kind
    public let target: String
    public let label: String

    public init(id: String = UUID().uuidString, kind: Kind, target: String, label: String) {
        self.id = id
        self.kind = kind
        self.target = target
        self.label = label
    }
}

/// The tray: every mission, and the rules about what may run unattended.
public struct MissionTray: Sendable, Equatable {
    public private(set) var missions: [TrayMission]

    /// How many run at once. More than two competing for the same model and the same disk makes
    /// each one slower and the machine noticeably worse to use.
    public static let concurrencyLimit = 2

    public init(missions: [TrayMission] = []) {
        self.missions = missions
    }

    public var active: [TrayMission] { missions.filter { !$0.state.isFinished } }
    public var finished: [TrayMission] { missions.filter(\.state.isFinished) }

    /// What the badge shows. Only things waiting on the person: a count that includes work quietly
    /// in progress trains people to ignore the badge.
    public var attentionCount: Int { missions.filter(\.state.needsYou).count }

    public var canStartAnother: Bool {
        missions.filter { $0.state == .working || $0.state == .preparing }.count
            < Self.concurrencyLimit
    }

    public mutating func add(_ mission: TrayMission) {
        missions.insert(mission, at: 0)
    }

    public mutating func update(_ id: String, _ change: (inout TrayMission) -> Void) {
        guard let index = missions.firstIndex(where: { $0.id == id }) else { return }
        change(&missions[index])
        if missions[index].state.isFinished, missions[index].finishedAt == nil {
            missions[index].finishedAt = .now
        }
    }

    public mutating func note(_ id: String, did line: String) {
        update(id) { $0.performed.append(line) }
    }

    public mutating func cancel(_ id: String) {
        update(id) { mission in
            guard !mission.state.isFinished else { return }
            mission.state = .cancelled
        }
    }

    /// Clears out what is done, keeping anything unfinished.
    public mutating func clearFinished() {
        missions.removeAll(where: \.state.isFinished)
    }

    /// Everything still undoable, newest first, because the thing you just did is the thing you
    /// are most likely to want back.
    public var undoable: [(mission: TrayMission, step: UndoableStep)] {
        missions
            .filter { $0.state == .completed }
            .flatMap { mission in mission.undoable.map { (mission, $0) } }
    }
}
