import Foundation

/// Durable operational state for work that may outlive a window or a process.
///
/// This is deliberately a snapshot, not a serialized executable action. A restart must never
/// replay a side effect silently; an interrupted run is surfaced so the person can choose whether
/// to run it again.
public struct ActionRunSnapshot: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable, Equatable {
        case running
        case completed
        case failed
        case cancelled
        case interrupted

        public var label: String {
            switch self {
            case .running: return L("Running")
            case .completed: return L("Completed")
            case .failed: return L("Failed")
            case .cancelled: return L("Cancelled")
            case .interrupted: return L("Interrupted")
            }
        }
    }

    public struct Step: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public var outcome: String
        public var detail: String

        public init(id: String, title: String, outcome: String, detail: String) {
            self.id = id
            self.title = title
            self.outcome = outcome
            self.detail = detail
        }
    }

    public let id: String
    public let intent: String
    /// Kept only so an interrupted run can be reviewed and approved again. Recovery never executes it.
    public let mission: Mission?
    public var state: State
    public var steps: [Step]
    public let createdAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?
    public var failure: String?
    public var receipt: String?

    public init(id: String, intent: String, mission: Mission? = nil, state: State = .running, steps: [Step] = [],
                createdAt: Date = .now, updatedAt: Date = .now, finishedAt: Date? = nil,
                failure: String? = nil, receipt: String? = nil) {
        self.id = id
        self.intent = intent
        self.mission = mission
        self.state = state
        self.steps = steps
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
        self.failure = failure
        self.receipt = receipt
    }
}

public struct ActionDraftSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let mission: Mission
    public let savedAt: Date

    public init(mission: Mission, savedAt: Date = .now) {
        self.id = mission.id
        self.mission = mission
        self.savedAt = savedAt
    }
}

@MainActor
extension Store {
    public func saveActionDraft(_ draft: ActionDraftSnapshot) {
        guard let data = try? JSONEncoder().encode(draft),
              let payload = String(data: data, encoding: .utf8) else { return }
        try? database.execute("""
            INSERT INTO action_drafts (id, intent, payload, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET intent = excluded.intent,
                payload = excluded.payload, updatedAt = excluded.updatedAt
            """, [.text(draft.id), .text(draft.mission.intent), .text(payload),
                  .double(draft.mission.createdAt.timeIntervalSince1970),
                  .double(draft.savedAt.timeIntervalSince1970)])
    }

    public func actionDrafts() -> [ActionDraftSnapshot] {
        let rows = (try? database.query("SELECT payload FROM action_drafts ORDER BY updatedAt DESC")) ?? []
        return rows.compactMap { row in
            guard let data = row.string("payload").data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ActionDraftSnapshot.self, from: data)
        }
    }

    public func deleteActionDraft(id: String) {
        try? database.execute("DELETE FROM action_drafts WHERE id = ?", [.text(id)])
    }

    public func clearActionDrafts() {
        try? database.execute("DELETE FROM action_drafts")
    }

    public func saveActionRun(_ run: ActionRunSnapshot) {
        guard let data = try? JSONEncoder().encode(run),
              let payload = String(data: data, encoding: .utf8) else { return }
        try? database.execute("""
            INSERT INTO missions (id, intent, state, payload, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET intent = excluded.intent,
                state = excluded.state, payload = excluded.payload,
                updatedAt = excluded.updatedAt
            """, [.text(run.id), .text(run.intent), .text(run.state.rawValue), .text(payload),
                  .double(run.createdAt.timeIntervalSince1970),
                  .double(run.updatedAt.timeIntervalSince1970)])
    }

    public func actionRuns(limit: Int = 50) -> [ActionRunSnapshot] {
        let rows = (try? database.query(
            "SELECT payload FROM missions ORDER BY updatedAt DESC LIMIT ?", [.int(Int64(limit))]
        )) ?? []
        return rows.compactMap { row in
            guard let data = row.string("payload").data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ActionRunSnapshot.self, from: data)
        }
    }

    /// A process can disappear between two side effects. The safe recovery is visible
    /// interruption, never an automatic replay of the last action.
    @discardableResult
    public func markInterruptedActionRuns() -> Int {
        let active = actionRuns(limit: 200).filter { $0.state == .running }
        for var run in active {
            run.state = .interrupted
            run.updatedAt = .now
            run.finishedAt = .now
            run.failure = L("The app closed before this action finished.")
            saveActionRun(run)
        }
        return active.count
    }
}

extension ActionRunSnapshot {
    /// Reopens an interrupted run as a fresh approval draft. The original snapshot remains an
    /// audit record; nothing here mutates it or invokes an action.
    public func missionForReview() -> Mission? {
        guard state == .interrupted, var mission else { return nil }
        mission.state = .awaitingApproval
        mission.finishedAt = nil
        mission.failure = nil
        for index in mission.steps.indices {
            mission.steps[index].outcome = .pending
            mission.steps[index].detail = ""
        }
        return mission
    }

    public init(mission: Mission, receipt: String? = nil) {
        let state: State
        switch mission.state {
        case .planning, .awaitingApproval, .running: state = .running
        case .done: state = .completed
        case .failed: state = .failed
        case .cancelled: state = .cancelled
        }
        self.init(id: mission.id, intent: mission.intent, mission: mission, state: state,
                  steps: mission.steps.map { Step(id: $0.id, title: $0.title,
                                                  outcome: $0.outcome.rawValue, detail: $0.detail) },
                  createdAt: mission.createdAt, updatedAt: .now,
                  finishedAt: mission.finishedAt, failure: mission.failure, receipt: receipt)
    }
}
