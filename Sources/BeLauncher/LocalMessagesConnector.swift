import Foundation
import SQLite3
import BeLauncherCore

/// Bounded, read-only connector for the local Messages database. It reads text rows only and
/// keeps `chat.db` as the source reference; attachments and attributed bodies are deliberately out.
enum LocalMessagesConnector {
    struct Reading: Sendable {
        let messages: [MessageRecord]
        let problem: String?
    }

    private struct OpenedDatabase {
        let handle: OpaquePointer
        let directory: URL
    }

    static func read(since: Date, home: String = NSHomeDirectory(), limit: Int = 300) -> Reading {
        let path = (home as NSString).appendingPathComponent("Library/Messages/chat.db")
        guard FileManager.default.fileExists(atPath: path) else {
            return Reading(messages: [], problem: nil)
        }
        guard let opened = openCopy(path) else {
            return Reading(messages: [], problem: L("I cannot read Apple Messages. macOS protects its local database; give BeLauncher Full Disk Access in System Settings, Privacy & Security."))
        }
        let handle = opened.handle
        defer {
            sqlite3_close_v2(handle)
            try? FileManager.default.removeItem(at: opened.directory)
        }

        let sql = """
            SELECT m.guid, m.text, m.date, m.is_from_me,
                   COALESCE(h.id, '')
            FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.date > ? AND m.text IS NOT NULL AND length(m.text) > 0
              AND COALESCE(m.is_system_message, 0) = 0
            ORDER BY m.date DESC LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return Reading(messages: [], problem: L("Apple Messages could not be read because its local database is unavailable."))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64((since.timeIntervalSince1970 - 978_307_200) * 1_000_000_000))
        sqlite3_bind_int64(statement, 2, Int64(limit))

        var result: [MessageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let guid = sqlite3_column_text(statement, 0),
                  let text = sqlite3_column_text(statement, 1) else { continue }
            let rawDate = sqlite3_column_int64(statement, 2)
            let seconds = rawDate > 10_000_000_000
                ? Double(rawDate) / 1_000_000_000 + 978_307_200
                : Double(rawDate) + 978_307_200
            let sender = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
            result.append(MessageRecord(
                at: Date(timeIntervalSince1970: seconds), text: String(cString: text),
                sender: sender, sourcePath: path, messageID: String(cString: guid),
                isFromMe: sqlite3_column_int(statement, 3) != 0))
        }
        return Reading(messages: result, problem: nil)
    }

    private static func openCopy(_ path: String) -> OpenedDatabase? {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("belauncher-messages-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("chat.db")
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: path + suffix),
                                              to: directory.appendingPathComponent("chat.db" + suffix))
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let handle { sqlite3_close_v2(handle) }
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        guard let handle else { try? FileManager.default.removeItem(at: directory); return nil }
        return OpenedDatabase(handle: handle, directory: directory)
    }
}
