import Foundation
@preconcurrency import EventKit
import BeLauncherCore

struct BELReminderActionInput: Codable, Sendable {
    let query: String
    init(query: String = "") { self.query = query }
}

/// Deterministic read-only search against the user's local Reminders database.
struct ReminderActionHandler: BELActionHandler {
    let actionID = "reminders.find"

    init?(definition: BELActionDefinition) {
        guard definition.id == actionID, definition.adapter == .publicAPI else { return nil }
    }

    func perform(input: Data) async throws -> BELActionResult {
        let value = try JSONDecoder().decode(BELReminderActionInput.self, from: input)
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw ReminderActionError.permission
        }
        let store = EKEventStore()
        let predicate = store.predicateForReminders(in: nil)
        let query = value.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines: [String] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { items in
                let lines = (items ?? []).filter { !$0.isCompleted }
                    .filter { query.isEmpty || ($0.title ?? "").localizedCaseInsensitiveContains(query) ||
                        $0.calendar.title.localizedCaseInsensitiveContains(query) }
                    .prefix(30)
                    .map { item in
                        let due = item.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                            .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? L("No due date")
                        return "\(item.title ?? L("Untitled")) — \(item.calendar.title) · \(due)"
                    }
                continuation.resume(returning: lines)
            }
        }
        guard !lines.isEmpty else { throw ReminderActionError.noMatches }
        return BELActionResult(text: lines.joined(separator: "\n"), receipt: "reminders:find")
    }
}

enum ReminderActionError: Error, Equatable {
    case permission
    case noMatches
}
