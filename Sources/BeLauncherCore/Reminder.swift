import Foundation

/// A small, UI- and EventKit-independent representation of a reminder.
/// Keeping this in Core makes search and formatting testable without a user's database.
public struct ReminderItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let list: String
    public let dueDate: Date?
    public let notes: String

    public init(id: String, title: String, list: String, dueDate: Date? = nil, notes: String = "") {
        self.id = id
        self.title = title
        self.list = list
        self.dueDate = dueDate
        self.notes = notes
    }

    public var searchableText: String { "\(title) \(list) \(notes)" }

    public var displayDueDate: String {
        guard let dueDate else { return L("No due date") }
        return dueDate.formatted(date: .abbreviated, time: .shortened)
    }
}
