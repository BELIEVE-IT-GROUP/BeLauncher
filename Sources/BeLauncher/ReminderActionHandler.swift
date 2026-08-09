import Foundation
@preconcurrency import EventKit
import BeLauncherCore

struct BELReminderActionInput: Codable, Sendable {
    let query: String
    let reminderID: String?
    let title: String?
    let list: String?
    let dueDate: Date?
    init(query: String = "", reminderID: String? = nil, title: String? = nil,
         list: String? = nil, dueDate: Date? = nil) {
        self.query = query; self.reminderID = reminderID; self.title = title
        self.list = list; self.dueDate = dueDate
    }
}

/// Deterministic operations against the user's local Reminders database.
struct ReminderActionHandler: BELActionHandler {
    let actionID: String

    init?(definition: BELActionDefinition) {
        guard ["reminders.find", "reminders.create", "reminders.complete"].contains(definition.id),
              definition.adapter == .publicAPI else { return nil }
        actionID = definition.id
    }

    func perform(input: Data) async throws -> BELActionResult {
        let value = try JSONDecoder().decode(BELReminderActionInput.self, from: input)
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw ReminderActionError.permission
        }
        let store = EKEventStore()
        if actionID == "reminders.create" {
            let title = value.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { throw ReminderActionError.invalidInput }
            let calendar = store.calendars(for: .reminder).first {
                guard let list = value.list, !list.isEmpty else { return true }
                return $0.title.localizedCaseInsensitiveCompare(list) == .orderedSame
            }
            guard let calendar else { throw ReminderActionError.noList }
            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.calendar = calendar
            if let dueDate = value.dueDate {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: dueDate)
            }
            try store.save(reminder, commit: true)
            return BELActionResult(text: L("Reminder created: %@", title),
                                   changed: [reminder.calendarItemIdentifier],
                                   receipt: "reminders:create:\(reminder.calendarItemIdentifier)")
        }
        if actionID == "reminders.complete" {
            guard let id = value.reminderID,
                  let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
                throw ReminderActionError.noMatches
            }
            reminder.isCompleted = true
            try store.save(reminder, commit: true)
            return BELActionResult(text: L("Completed: %@", reminder.title ?? L("Untitled")),
                                   changed: [id], receipt: "reminders:complete:\(id)")
        }
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
    case noList
    case invalidInput
}
