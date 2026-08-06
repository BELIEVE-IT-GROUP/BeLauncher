import Foundation
import SQLite3
import BeLauncherCore

/// What was open in the browser, read from the browser's own history.
///
/// This is the cheapest large source there is. Both browsers already keep a full SQLite history in
/// the user's home folder, so there is nothing to observe, no extension to install and no daemon
/// watching tabs — the file is already theirs and already written.
///
/// Three things make it harder than it sounds, and all three were verified on a real machine
/// rather than assumed:
///
/// 1. **The file is locked while the browser runs.** Opening it read-only is not enough: Safari
///    keeps a write-ahead log, and a reader that ignores the `-wal` sees a history that stops
///    hours ago. So the database and its sidecars are copied to a temporary folder and the copy is
///    what gets read.
/// 2. **The two epochs are different, and neither is Unix time.** Measured on this Mac against
///    known visits: Safari stores seconds since 2001-01-01 (a row reading `803575494.358164`
///    resolves to 2026-06-19 10:24 once `978307200` is added), Chrome stores *microseconds* since
///    1601-01-01 (`13430270367690358` resolves to 2026-08-03 17:39 after dividing by a million and
///    subtracting `11644473600`). Getting either wrong does not throw — it silently files a whole
///    history under the wrong decade, where it ranks last forever and looks like the feature simply
///    does not work.
/// 3. **Safari's folder is protected by TCC.** Without Full Disk Access the copy fails with a
///    permission error, which has to be said in words rather than swallowed into an empty list.
enum BrowserHistory {

    /// Seconds between 2001-01-01 and the Unix epoch. Safari's `visit_time` is offset by this.
    static let appleEpochOffset: TimeInterval = 978_307_200
    /// Seconds between 1601-01-01 and the Unix epoch. Chromium's `last_visit_time` is offset by
    /// this, and is counted in microseconds rather than seconds.
    static let windowsEpochOffset: TimeInterval = 11_644_473_600

    struct Reading: Sendable {
        var visits: [BrowserVisit] = []
        /// Said out loud when a browser could not be read, so the reason reaches the person instead
        /// of the log. Empty when everything that exists was read.
        var problems: [String] = []
    }

    /// Reads every browser installed on this Mac.
    ///
    /// `nonisolated` and free of any shared state: this runs off the main actor from the corpus
    /// pass, and copying tens of megabytes on the main thread would stall the hot key.
    static func read(since: Date, excludedDomains: Set<String>, excludedApps: Set<String>,
                     limit: Int = 3_000, home: String = NSHomeDirectory()) -> Reading {
        var reading = Reading()

        let safariPath = (home as NSString).appendingPathComponent("Library/Safari/History.db")
        if FileManager.default.fileExists(atPath: safariPath) {
            do {
                reading.visits += try safari(at: safariPath, since: since, limit: limit)
            } catch {
                reading.problems.append(describe(error, browser: "Safari"))
            }
        }

        for profile in chromeProfiles(home: home) {
            do {
                reading.visits += try chrome(at: profile, since: since, limit: limit)
            } catch {
                reading.problems.append(describe(error, browser: "Chrome"))
            }
        }

        // Filtered here, before anything is handed on. Reading a bank page into memory and dropping
        // it two layers later still means the page was read; the exclusion has to bite at the point
        // the row leaves SQLite.
        reading.visits = reading.visits.filter { visit in
            !Privacy.isExcluded(bundleIdentifier: nil, url: visit.url,
                                apps: excludedApps, domains: excludedDomains)
        }
        reading.visits.sort { $0.at < $1.at }
        return reading
    }

    // MARK: - Safari

    static func safari(at path: String, since: Date, limit: Int) throws -> [BrowserVisit] {
        try withCopy(of: path) { handle in
            // The title lives on the visit, not on the item: the same URL visited twice can have
            // two different titles, and the item row has no title column at all.
            let sql = """
                SELECT v.visit_time AS at, i.url AS url, v.title AS title
                FROM history_visits v JOIN history_items i ON i.id = v.history_item
                WHERE v.visit_time > ? AND v.title IS NOT NULL AND i.url IS NOT NULL
                ORDER BY v.visit_time DESC LIMIT ?
                """
            let floor = since.timeIntervalSince1970 - appleEpochOffset
            return query(handle, sql, floor: floor, limit: limit) { at, url, title in
                BrowserVisit(at: Date(timeIntervalSince1970: at + appleEpochOffset),
                             url: url, title: title, browser: "Safari")
            }
        }
    }

    // MARK: - Chrome

    /// Every Chrome profile, not only `Default`.
    ///
    /// A person with a work profile and a personal one keeps all their work in `Profile 1`, and a
    /// reader that only knows about `Default` finds an empty history and reports success.
    static func chromeProfiles(home: String) -> [String] {
        let root = (home as NSString)
            .appendingPathComponent("Library/Application Support/Google/Chrome")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return entries
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .map { (root as NSString).appendingPathComponent($0 + "/History") }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .sorted()
    }

    static func chrome(at path: String, since: Date, limit: Int) throws -> [BrowserVisit] {
        try withCopy(of: path) { handle in
            let sql = """
                SELECT v.visit_time AS at, u.url AS url, u.title AS title
                FROM visits v JOIN urls u ON u.id = v.url
                WHERE v.visit_time > ? AND u.title IS NOT NULL AND u.url IS NOT NULL
                ORDER BY v.visit_time DESC LIMIT ?
                """
            let floor = (since.timeIntervalSince1970 + windowsEpochOffset) * 1_000_000
            return query(handle, sql, floor: floor, limit: limit) { at, url, title in
                let seconds = at / 1_000_000 - windowsEpochOffset
                return BrowserVisit(at: Date(timeIntervalSince1970: seconds),
                                    url: url, title: title, browser: "Chrome")
            }
        }
    }

    // MARK: - Reading a locked database

    /// Copies a database and its sidecars somewhere private, then reads the copy.
    ///
    /// `immutable=1` on the original was tried first and is wrong: it tells SQLite to ignore the
    /// write-ahead log, which on a running browser means everything since the last checkpoint is
    /// invisible. Copying costs a few tens of megabytes of temporary disk once a pass and returns
    /// the history the person actually has.
    static func withCopy<T>(of path: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        let fileManager = FileManager.default
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("belauncher-history-" + UUID().uuidString)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }

        let name = (path as NSString).lastPathComponent
        let copy = folder.appendingPathComponent(name)
        try fileManager.copyItem(at: URL(fileURLWithPath: path), to: copy)
        for suffix in ["-wal", "-shm"] where fileManager.fileExists(atPath: path + suffix) {
            try? fileManager.copyItem(at: URL(fileURLWithPath: path + suffix),
                                      to: folder.appendingPathComponent(name + suffix))
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw Failure.unreadable(name)
        }
        defer { sqlite3_close_v2(handle) }
        return try body(handle)
    }

    /// Runs one history query. Both browsers answer the same three columns, so the row reading is
    /// shared and only the epoch arithmetic differs.
    static func query(_ handle: OpaquePointer, _ sql: String, floor: Double, limit: Int,
                      make: (Double, String, String) -> BrowserVisit) -> [BrowserVisit] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, floor)
        sqlite3_bind_int64(statement, 2, Int64(limit))

        var result: [BrowserVisit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            // Read as a double for both browsers even though Chrome's column is an integer:
            // 1.34e16 microseconds exceeds the 2^53 a Double holds exactly, but the rounding that
            // costs is about two microseconds on a timestamp, which no episode boundary can see.
            let at = sqlite3_column_double(statement, 0)
            guard at > 0 else { continue }
            guard let rawURL = sqlite3_column_text(statement, 1),
                  let rawTitle = sqlite3_column_text(statement, 2) else { continue }
            let title = String(cString: rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            result.append(make(at, String(cString: rawURL), title))
        }
        return result
    }

    // MARK: - Saying what went wrong

    enum Failure: Error {
        case unreadable(String)
    }

    /// Turns a copy failure into something a person can act on.
    ///
    /// The permission case is called out by name because it is the only one with a fix, and because
    /// the generic message macOS produces — "no tienes permiso" against a path inside the user's own
    /// home folder — reads like a bug in the app rather than a switch nobody has flipped.
    static func describe(_ error: Error, browser: String) -> String {
        let code = (error as NSError).code
        let denied = code == NSFileReadNoPermissionError || code == NSFileWriteNoPermissionError
        if denied || browser == "Safari" && (error as NSError).domain == NSCocoaErrorDomain {
            return L("I cannot read %@'s history. macOS protects it: give BeLauncher Full Disk Access in System Settings, Privacy & Security.",
                     browser)
        }
        return L("I could not read %1$@'s history: %2$@", browser, error.localizedDescription)
    }
}
