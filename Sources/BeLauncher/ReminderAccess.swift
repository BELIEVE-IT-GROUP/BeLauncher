import Foundation
@preconcurrency import EventKit
import BeLauncherCore

/// Read-only first slice of the Reminders bridge. It never asks for permission while typing.
@MainActor
final class ReminderAccess {
    private let store = EKEventStore()
    private(set) var reminders: [ReminderItem] = []
    private(set) var completedReminders: [ReminderItem] = []
    private(set) var lastError: String?
    private var hasAsked = false

    var isAuthorised: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    func requestAccessIfNeeded() async {
        guard !isAuthorised, !hasAsked else { return }
        hasAsked = true
        do {
            if try await store.requestFullAccessToReminders() {
                await refresh()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refresh() async {
        guard isAuthorised else { return }
        let predicate = store.predicateForReminders(in: nil)
        let result: ([ReminderItem], [ReminderItem]) = await withCheckedContinuation { continuation in
            // EventKit answers on its own queue, not ours. Without @Sendable the closure inherits
            // this type's MainActor isolation, and the runtime executor check trips on it: a
            // warning on macOS 26, a SIGTRAP at launch on macOS 27. Nothing here touches the
            // actor's state, so the mapping is free to run wherever EventKit calls us.
            store.fetchReminders(matching: predicate) { @Sendable items in
                let map: (EKReminder) -> ReminderItem? = { item in
                        guard let title = item.title, !title.isEmpty else { return nil }
                        return ReminderItem(
                            id: item.calendarItemIdentifier,
                            title: title,
                            list: item.calendar.title,
                            dueDate: item.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                            notes: item.notes ?? ""
                        )
                }
                let pending = (items ?? []).filter { !$0.isCompleted }.compactMap(map)
                    .sorted { ($0.dueDate ?? .distantFuture, $0.title) <
                              ($1.dueDate ?? .distantFuture, $1.title) }
                let completed = (items ?? []).filter(\.isCompleted).compactMap(map)
                    .sorted { ($0.dueDate ?? .distantFuture, $0.title) <
                              ($1.dueDate ?? .distantFuture, $1.title) }
                continuation.resume(returning: (pending, completed))
            }
        }
        reminders = result.0
        completedReminders = result.1
    }
}
