import Foundation

/// What you did, in order, so the app can notice what you keep doing.
///
/// Nothing in the product can learn from your habits without a record of them, and `HabitDetector`
/// sat in the codebase for weeks with tests and no caller precisely because this did not exist. The
/// class looked implemented and the feature did not exist.
///
/// The reason it was not written is worth stating rather than hiding: a log of everything a person
/// does on their Mac is surveillance unless three things are true, and here they are the design.
/// It never leaves the machine. It is readable and deletable in Settings, in plain language, not as
/// a hex dump. And it records *what kind of thing* you did, never the contents — opening a document
/// is logged as opening that application, not as the text inside it.
public struct LoggedAction: Sendable, Equatable, Identifiable {
    public let id: Int64
    /// A stable name for the kind of thing done: `app:Notion`, `flow:enfoque`, `system:dnd`.
    public let signature: String
    /// What to show a person reading their own log.
    public let label: String
    public let at: Date

    public init(id: Int64 = 0, signature: String, label: String, at: Date = .now) {
        self.id = id
        self.signature = signature
        self.label = label
        self.at = at
    }
}

extension Store {

    /// Whether anything is recorded at all. Off is a real option, and the log is useless rather
    /// than dangerous when empty, so the feature degrades to silence instead of to nagging.
    public var habitsEnabled: Bool { setting("habits_enabled", default: false) }

    public func recordAction(signature: String, label: String, at date: Date = .now) {
        guard habitsEnabled else { return }
        try? database.execute(
            "INSERT INTO action_log (signature, label, at) VALUES (?, ?, ?)",
            [.text(signature), .text(label), .double(date.timeIntervalSince1970)]
        )
        trimActionLog()
    }

    /// Oldest first, which is the order a sequence detector needs.
    public func actionLog(limit: Int = 600) -> [LoggedAction] {
        let rows = (try? database.query(
            "SELECT * FROM (SELECT * FROM action_log ORDER BY at DESC LIMIT ?) ORDER BY at ASC",
            [.int(Int64(limit))]
        )) ?? []
        return rows.map {
            LoggedAction(id: $0.int("id"), signature: $0.string("signature"),
                         label: $0.string("label"),
                         at: Date(timeIntervalSince1970: $0.double("at")))
        }
    }

    /// How much history is kept. Two weeks is enough for a habit to show up four times and short
    /// enough that nobody is carrying a year of their own movements around.
    public static let habitRetentionDays = 14

    func trimActionLog() {
        let cutoff = Date().addingTimeInterval(-Double(Store.habitRetentionDays) * 86_400)
        try? database.execute("DELETE FROM action_log WHERE at < ?",
                              [.double(cutoff.timeIntervalSince1970)])
    }

    public func clearActionLog() {
        try? database.execute("DELETE FROM action_log")
    }

    // MARK: - Recipes offered and refused

    /// A habit the person was already offered. Without this the same suggestion reappears every
    /// time the window opens, which is how a helpful feature becomes something people switch off.
    public func markRecipeOffered(_ key: String, accepted: Bool) {
        try? database.execute(
            "INSERT INTO recipe_offers (key, accepted, at) VALUES (?, ?, ?) "
            + "ON CONFLICT(key) DO UPDATE SET accepted = excluded.accepted, at = excluded.at",
            [.text(key), .int(accepted ? 1 : 0), .double(Date().timeIntervalSince1970)]
        )
    }

    public func recipeAlreadyOffered(_ key: String) -> Bool {
        let rows = (try? database.query("SELECT key FROM recipe_offers WHERE key = ?",
                                        [.text(key)])) ?? []
        return !rows.isEmpty
    }

    public func clearRecipeOffers() {
        try? database.execute("DELETE FROM recipe_offers")
    }
}
