import Foundation
@preconcurrency import EventKit
import BeLauncherCore

struct BELCalendarActionInput: Codable, Sendable {
    let daysAhead: Int

    init(daysAhead: Int = 7) {
        self.daysAhead = daysAhead
    }
}

/// A read-only EventKit adapter. Permission is checked by BELActionExecutor before this runs;
/// this handler never opens a system prompt as a side effect of a launcher command.
struct CalendarActionHandler: BELActionHandler {
    let actionID = "calendar.upcoming"

    init?(definition: BELActionDefinition) {
        guard definition.id == actionID, definition.adapter == .publicAPI else { return nil }
    }

    func perform(input: Data) async throws -> BELActionResult {
        let value = try JSONDecoder().decode(BELCalendarActionInput.self, from: input)
        let daysAhead = min(max(value.daysAhead, 1), 31)
        return try await MainActor.run {
            let status = EKEventStore.authorizationStatus(for: .event)
            guard status == .fullAccess else { throw CalendarActionError.permission }
            let store = EKEventStore()
            let now = Date.now
            guard let end = Calendar.current.date(byAdding: .day, value: daysAhead, to: now) else {
                throw CalendarActionError.invalidRange
            }
            let events = store.events(matching: store.predicateForEvents(withStart: now, end: end,
                                                                          calendars: nil))
                .filter { !$0.isAllDay }
                .sorted { $0.startDate < $1.startDate }
            guard !events.isEmpty else { throw CalendarActionError.noEvents }
            let lines = events.prefix(20).map { event in
                "\(event.startDate.formatted(date: .abbreviated, time: .shortened)) — \(event.title ?? L("No title"))"
            }
            return BELActionResult(text: lines.joined(separator: "\n"), receipt: "calendar:upcoming")
        }
    }
}

enum CalendarActionError: Error, Equatable {
    case permission
    case invalidRange
    case noEvents
}
