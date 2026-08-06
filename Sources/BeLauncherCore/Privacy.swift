import Foundation

/// The controls that have to exist before capturing anything else.
///
/// Every source added after this one makes the brain better and the promise heavier. Asking
/// someone to let an app watch what they open, what they read and what they say is only fair if
/// the same app can be told to stop, told to look away from certain things, and told to forget a
/// stretch of time — and if all three take one action, not a support ticket.
///
/// So this is a prerequisite rather than a feature. Nothing in wave two ships without it.
public enum Privacy {

    /// Why capture is not running.
    public enum PauseReason: String, Sendable, Equatable, Codable {
        case notPaused
        /// Turned off by hand, until turned back on.
        case byHand
        /// Turned off for a while.
        case untilLater
        // There used to be a `sharingScreen` case here, offered as a control and never wired to
        // anything: no macOS API reports that somebody else is capturing your screen. It was
        // checked on this machine rather than assumed — CGDisplayIsCaptured is unavailable,
        // CGSessionCopyCurrentDictionary carries no such key, and ScreenCaptureKit only describes
        // what this app may capture. Guessing from a list of video-call apps would miss a screen
        // shared from a browser tab, so it would be off exactly when somebody believed it was on.
        // A control that does nothing is worse than one never offered.

        public var label: String {
            switch self {
            case .notPaused: "Capturando"
            case .byHand: "En pausa"
            case .untilLater: "En pausa un rato"
            }
        }
    }

    public struct State: Sendable, Equatable {
        public let reason: PauseReason
        /// When it resumes on its own. Absent for an indefinite pause.
        public let until: Date?

        public init(reason: PauseReason = .notPaused, until: Date? = nil) {
            self.reason = reason
            self.until = until
        }

        public func isCapturing(at date: Date = .now) -> Bool {
            switch reason {
            case .notPaused: true
            case .byHand: false
            case .untilLater: until.map { date >= $0 } ?? true
            }
        }

        /// Said plainly, because a paused brain that looks like a working one is the worst of both.
        public func summary(at date: Date = .now) -> String {
            if isCapturing(at: date) { return "Capturando lo que haces." }
            if reason == .untilLater, let until {
                let minutes = max(1, Int(until.timeIntervalSince(date) / 60))
                return "En pausa. Vuelve solo en \(minutes) min."
            }
            return reason.label + ". No se está guardando nada."
        }
    }

    /// Apps and sites the brain never looks at.
    ///
    /// Shipped with a default list rather than empty. An empty exclusion list means the first
    /// password manager window, the first bank tab and the first private conversation all go in
    /// before anybody thinks to configure anything, and by then it is too late to un-see them.
    public static let excludedByDefault: [String] = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.dashlane.Dashlane", "in.sinew.Enpass-Desktop",
        "com.apple.Passwords",
    ]

    /// Domains excluded by default, for when browsing is captured.
    public static let excludedDomainsByDefault: [String] = [
        "bank", "banco", "bbva", "santander", "chase.com", "paypal.com",
        "vault.", "1password.com", "bitwarden.com", "accounts.google.com/signin",
        "login.", "signin.", "auth.",
    ]

    /// Whether something is off limits.
    ///
    /// Bundle identifiers match exactly and domains by substring: an app is one thing with one
    /// name, while a bank shows up as three hostnames and a redirect.
    public static func isExcluded(bundleIdentifier: String?, url: String?,
                                  apps: Set<String>, domains: Set<String>) -> Bool {
        if let bundleIdentifier, apps.contains(bundleIdentifier) { return true }
        if let url {
            let lowered = url.lowercased()
            if domains.contains(where: { !$0.isEmpty && lowered.contains($0) }) { return true }
        }
        return false
    }

    /// A stretch of time to forget.
    public struct Period: Sendable, Equatable {
        public let from: Date
        public let to: Date

        public init(from: Date, to: Date) {
            self.from = min(from, to)
            self.to = max(from, to)
        }

        public func contains(_ date: Date) -> Bool { date >= from && date <= to }

        /// Common ways of saying it, so forgetting is one action rather than a date picker.
        public static func lastHour(now: Date = .now) -> Period {
            Period(from: now.addingTimeInterval(-3600), to: now)
        }

        public static func today(now: Date = .now, calendar: Calendar = .current) -> Period {
            Period(from: calendar.startOfDay(for: now), to: now)
        }

        public static func afternoon(of day: Date, calendar: Calendar = .current) -> Period {
            let start = calendar.date(bySettingHour: 13, minute: 0, second: 0, of: day) ?? day
            let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: day) ?? day
            return Period(from: start, to: end)
        }
    }

    /// What forgetting a period actually removes, said before it happens.
    ///
    /// Shown as a count rather than done silently, because this is the one irreversible action in
    /// the app. Somebody who meant to forget an hour and is about to forget a month should find
    /// out from a sentence, not from the hole it leaves.
    public struct Forgetting: Sendable, Equatable {
        public let passages: Int
        public let clips: Int
        public let nodes: Int

        public init(passages: Int, clips: Int, nodes: Int) {
            self.passages = passages
            self.clips = clips
            self.nodes = nodes
        }

        public var total: Int { passages + clips + nodes }
        public var isEmpty: Bool { total == 0 }

        public var warning: String {
            guard !isEmpty else { return "En ese rato no hay nada guardado." }
            var parts: [String] = []
            if passages > 0 { parts.append("\(passages) pasaje(s)") }
            if clips > 0 { parts.append("\(clips) del portapapeles") }
            if nodes > 0 { parts.append("\(nodes) del grafo") }
            return "Se borra para siempre: " + parts.joined(separator: ", ") + "."
        }
    }
}

// MARK: - Storage

extension Store {

    public var privacyState: Privacy.State {
        let reason = Privacy.PauseReason(rawValue: (setting("capture_pause") ?? "")) ?? .notPaused
        let until = Double(setting("capture_pause_until") ?? "") ?? 0
        return Privacy.State(reason: reason, until: until > 0 ? Date(timeIntervalSince1970: until) : nil)
    }

    public func pauseCapture(_ reason: Privacy.PauseReason, until: Date? = nil) {
        setSetting("capture_pause", reason == .notPaused ? "" : reason.rawValue)
        setSetting("capture_pause_until", until.map { String($0.timeIntervalSince1970) } ?? "")
    }

    /// The exclusion list the clipboard already used, now covering every source.
    ///
    /// One list, not two. A person who told the app to stay out of their password manager said it
    /// once and meant it for everything — discovering later that the rule only applied to copies
    /// is exactly the kind of surprise that makes a privacy control worthless.
    public func excludedFromCapture() -> Set<String> {
        let configured = excludedApps()
        return configured.isEmpty ? Set(Privacy.excludedByDefault) : configured
    }

    public func excludedDomains() -> Set<String> {
        let stored = (setting("capture_excluded_domains") ?? "")
        guard !stored.isEmpty else { return Set(Privacy.excludedDomainsByDefault) }
        return stored == "·vacía·" ? [] : Set(stored.split(whereSeparator: \.isNewline).map(String.init))
    }

    public func setExcludedDomains(_ domains: Set<String>) {
        // An emptied list is stored as a marker rather than as "", so it is not mistaken for
        // "never configured" and silently refilled with the defaults.
        setSetting("capture_excluded_domains",
                   domains.isEmpty ? "·vacía·" : domains.sorted().joined(separator: "\n"))
    }

    /// What a period holds, counted before anything is removed.
    public func whatWouldBeForgotten(_ period: Privacy.Period) -> Privacy.Forgetting {
        func count(_ sql: String) -> Int {
            let rows = (try? database.query(sql, [.double(period.from.timeIntervalSince1970),
                                                  .double(period.to.timeIntervalSince1970)])) ?? []
            return Int(rows.first?.int("n") ?? 0)
        }
        return Privacy.Forgetting(
            passages: count("SELECT COUNT(*) AS n FROM passages WHERE occurred_at BETWEEN ? AND ?"),
            clips: count("SELECT COUNT(*) AS n FROM clips WHERE created_at BETWEEN ? AND ?"),
            nodes: count("SELECT COUNT(*) AS n FROM work_nodes WHERE lastSeen BETWEEN ? AND ?")
        )
    }

    /// Periods the person asked to forget.
    ///
    /// Kept forever, and this is not bookkeeping: the sources are re-read on every pass, and the
    /// identifiers are derived from content so the rebuild is exact. Without a ledger, forgetting
    /// an afternoon lasted until the next indexing run — half an hour — and the app said "para
    /// siempre" while it happened. A promise that expires silently is worse than one never made.
    public func forgottenPeriods() -> [Privacy.Period] {
        (setting("capture_forgotten") ?? "")
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let parts = line.split(separator: "|")
                guard parts.count == 2, let from = Double(parts[0]), let to = Double(parts[1])
                else { return nil }
                return Privacy.Period(from: Date(timeIntervalSince1970: from),
                                      to: Date(timeIntervalSince1970: to))
            }
    }

    func rememberForgotten(_ period: Privacy.Period) {
        var lines = forgottenPeriods().map { "\($0.from.timeIntervalSince1970)|\($0.to.timeIntervalSince1970)" }
        lines.append("\(period.from.timeIntervalSince1970)|\(period.to.timeIntervalSince1970)")
        setSetting("capture_forgotten", lines.joined(separator: "\n"))
    }

    /// Whether something that happened then is allowed back in.
    public func isForgotten(_ date: Date) -> Bool {
        forgottenPeriods().contains { $0.contains(date) }
    }

    /// Removes everything captured in that period, from every table it touched.
    ///
    /// The passage index goes too, not just the source rows. Deleting a clip and leaving its
    /// vectorised passage behind means the thing still answers questions after being forgotten,
    /// which is worse than never having offered to forget it.
    @discardableResult
    public func forget(_ period: Privacy.Period) -> Privacy.Forgetting {
        let counted = whatWouldBeForgotten(period)
        rememberForgotten(period)
        let bounds: [SQLValue] = [.double(period.from.timeIntervalSince1970),
                                  .double(period.to.timeIntervalSince1970)]
        try? database.execute("DELETE FROM passages WHERE occurred_at BETWEEN ? AND ?", bounds)
        try? database.execute("DELETE FROM clips WHERE created_at BETWEEN ? AND ?", bounds)
        try? database.execute("DELETE FROM work_nodes WHERE lastSeen BETWEEN ? AND ?", bounds)
        try? database.execute("DELETE FROM action_log WHERE at BETWEEN ? AND ?", bounds)
        // Edges whose ends are gone would keep a shape of what was forgotten.
        try? database.execute("""
            DELETE FROM work_edges WHERE source NOT IN (SELECT id FROM work_nodes)
               OR target NOT IN (SELECT id FROM work_nodes)
            """)
        return counted
    }
}
