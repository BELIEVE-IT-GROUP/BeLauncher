import EventKit
import BeLauncherCore

/// Reads the next few meetings, so "prepárame para…" works on day one instead of waiting months
/// for the brain to fill up. That is the whole reason this exists: a memory product that is
/// useless until you have fed it for a quarter never gets fed.
///
/// The permission is asked the first time a preparation needs it, with the capability already on
/// screen — never at launch alongside everything else.
@MainActor
final class CalendarAccess {
    private let store = EKEventStore()
    private(set) var events: [CalendarEvent] = []
    private(set) var lastError: String?
    private var hasAsked = false

    var isAuthorised: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Loads the window around today that a preparation could plausibly be about.
    func refresh(daysBack: Int = 2, daysAhead: Int = 7) {
        guard isAuthorised else { return }
        let calendar = Calendar.current
        let now = Date.now
        guard let start = calendar.date(byAdding: .day, value: -daysBack, to: now),
              let end = calendar.date(byAdding: .day, value: daysAhead, to: now) else { return }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map { event in
                CalendarEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? L("No title"),
                    start: event.startDate,
                    end: event.endDate,
                    attendees: (event.attendees ?? []).compactMap { $0.name },
                    notes: event.notes ?? ""
                )
            }
    }

    /// Asks once, explaining why first. Declining is fine: everything else keeps working.
    func requestAccessIfNeeded() async {
        guard !isAuthorised, !hasAsked else { return }
        hasAsked = true
        do {
            if try await store.requestFullAccessToEvents() {
                refresh()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
