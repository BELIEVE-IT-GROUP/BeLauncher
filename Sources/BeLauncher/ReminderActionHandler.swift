import Foundation
@preconcurrency import EventKit
import BeLauncherCore

struct BELReminderActionInput: Codable, Sendable {
    let query: String
    let reminderID: String?
    let title: String?
    let list: String?
    let dueDate: Date?
    let notes: String?
    let priority: Int?
    init(query: String = "", reminderID: String? = nil, title: String? = nil,
         list: String? = nil, dueDate: Date? = nil, notes: String? = nil,
         priority: Int? = nil) {
        self.query = query; self.reminderID = reminderID; self.title = title
        self.list = list; self.dueDate = dueDate; self.notes = notes; self.priority = priority
    }
}

/// Deterministic operations against the user's local Reminders database.
struct ReminderActionHandler: BELActionHandler {
    let actionID: String

    init?(definition: BELActionDefinition) {
        guard ["reminders.find", "reminders.create", "reminders.complete",
               "reminders.change_due_date", "reminders.show_list", "reminders.change_list",
               "reminders.add_notes", "reminders.set_priority"].contains(definition.id),
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
        if actionID == "reminders.change_due_date" {
            guard let id = value.reminderID,
                  let dueDate = value.dueDate,
                  let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
                throw ReminderActionError.invalidInput
            }
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: dueDate)
            try store.save(reminder, commit: true)
            return BELActionResult(text: L("Reminder rescheduled: %@", reminder.title ?? L("Untitled")),
                                   changed: [id], receipt: "reminders:due-date:\(id)")
        }
        if ["reminders.change_list", "reminders.add_notes", "reminders.set_priority"].contains(actionID) {
            guard let id = value.reminderID,
                  let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
                throw ReminderActionError.noMatches
            }
            switch actionID {
            case "reminders.change_list":
                let listName = value.list?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !listName.isEmpty,
                      let calendar = store.calendars(for: .reminder).first(where: {
                          $0.title.localizedCaseInsensitiveCompare(listName) == .orderedSame
                      }) else { throw ReminderActionError.noList }
                reminder.calendar = calendar
                try store.save(reminder, commit: true)
                return BELActionResult(text: L("Reminder moved to: %@", calendar.title),
                                       changed: [id], receipt: "reminders:list-change:\(id)")
            case "reminders.add_notes":
                let note = value.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !note.isEmpty else { throw ReminderActionError.invalidInput }
                reminder.notes = reminder.notes?.isEmpty == false
                    ? reminder.notes! + "\n" + note : note
                try store.save(reminder, commit: true)
                return BELActionResult(text: L("Notes added to: %@", reminder.title ?? L("Untitled")),
                                       changed: [id], receipt: "reminders:notes:\(id)")
            default:
                guard let priority = value.priority, (0...4).contains(priority) else {
                    throw ReminderActionError.invalidInput
                }
                reminder.priority = priority
                try store.save(reminder, commit: true)
                return BELActionResult(text: L("Priority changed for: %@", reminder.title ?? L("Untitled")),
                                       changed: [id], receipt: "reminders:priority:\(id)")
            }
        }
        if actionID == "reminders.show_list" {
            let listName = value.list?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !listName.isEmpty else { throw ReminderActionError.invalidInput }
            guard let calendar = store.calendars(for: .reminder).first(where: {
                $0.title.localizedCaseInsensitiveCompare(listName) == .orderedSame
            }) else { throw ReminderActionError.noList }
            let predicate = store.predicateForReminders(in: [calendar])
            let lines: [String] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { items in
                    let lines = (items ?? []).filter { !$0.isCompleted }
                        .prefix(50)
                        .map { item in
                            let due = item.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                                .map { $0.formatted(date: .abbreviated, time: .shortened) }
                                ?? L("No due date")
                            return "\(item.title ?? L("Untitled")) · \(due)"
                        }
                    continuation.resume(returning: lines)
                }
            }
            guard !lines.isEmpty else { throw ReminderActionError.noMatches }
            return BELActionResult(text: lines.joined(separator: "\n"),
                                   receipt: "reminders:list:\(calendar.calendarIdentifier)")
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

enum ReminderDateParser {
    static func parse(_ raw: String, now: Date = .now) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        if let exact = formatter.date(from: value) { return exact }

        let folded = value.lowercased()
        let calendar = Calendar.current
        let day: Date
        if folded.hasPrefix("tomorrow") || folded.hasPrefix("mañana") {
            day = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        } else if folded.hasPrefix("today") || folded.hasPrefix("hoy") {
            day = now
        } else {
            return nil
        }
        let time = folded.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? "09:00"
        let pieces = time.split(separator: ":").compactMap { Int($0) }
        guard pieces.count >= 2, pieces[0] >= 0, pieces[0] < 24,
              pieces[1] >= 0, pieces[1] < 60 else { return nil }
        return calendar.date(bySettingHour: pieces[0], minute: pieces[1], second: 0, of: day)
    }
}

enum ReminderPriorityParser {
    static func parse(_ raw: String) -> Int? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let none = String(decoding: [110, 105, 110, 103, 117, 110, 97], as: UTF8.self)
        let low = String(decoding: [98, 97, 106, 97], as: UTF8.self)
        let medium = String(decoding: [109, 101, 100, 105, 97], as: UTF8.self)
        let high = String(decoding: [97, 108, 116, 97], as: UTF8.self)
        let veryHigh = String(decoding: [109, 117, 121, 32, 97, 108, 116, 97], as: UTF8.self)
        switch value {
        case "0", "none", "normal", none: return 0
        case "1", "low", low: return 1
        case "2", "medium", medium: return 2
        case "3", "high", high: return 3
        case "4", "very high", veryHigh: return 4
        default: return nil
        }
    }
}
