import Foundation
import SQLite3
import BeLauncherCore

/// Reads only the plain snippet Apple Notes exposes in its local store. Encrypted and binary note
/// payloads are ignored; the database path and primary key remain the provenance reference.
enum LocalNotesConnector {
    struct Reading: Sendable {
        let notes: [NoteRecord]
        let problem: String?
    }

    static func read(since: Date, home: String = NSHomeDirectory(), limit: Int = 300) -> Reading {
        let path = (home as NSString).appendingPathComponent(
            "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
        guard FileManager.default.fileExists(atPath: path) else {
            return Reading(notes: [], problem: nil)
        }
        guard let handle = try? SQLiteReadOnly.openSnapshot(at: path) else {
            return Reading(notes: [], problem: L("I cannot read Apple Notes. macOS protects its local database; give BeLauncher Full Disk Access in System Settings, Privacy & Security."))
        }
        defer { handle.close() }

        let sql = """
            SELECT Z_PK, ZSNIPPET, COALESCE(ZMODIFICATIONDATE, ZMODIFIEDDATE, ZCREATIONDATE, 0)
            FROM ZICCLOUDSYNCINGOBJECT
            WHERE Z_ENT = 12 AND ZSNIPPET IS NOT NULL AND length(ZSNIPPET) > 0
              AND ZMARKEDFORDELETION = 0 AND ZMODIFICATIONDATE > ?
            ORDER BY ZMODIFICATIONDATE DESC LIMIT ?
            """
        guard let statement = handle.prepare(sql) else {
            return Reading(notes: [], problem: L("Apple Notes could not be read because its local database is unavailable."))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970 - 978_307_200)
        sqlite3_bind_int64(statement, 2, Int64(limit))

        var result: [NoteRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 1) else { continue }
            let clean = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 40 else { continue }
            let seconds = sqlite3_column_double(statement, 2) + 978_307_200
            result.append(NoteRecord(at: Date(timeIntervalSince1970: seconds), text: clean,
                                     sourcePath: path,
                                     noteID: String(sqlite3_column_int64(statement, 0))))
        }
        return Reading(notes: result, problem: nil)
    }
}

private struct SQLiteReadOnly {
    let handle: OpaquePointer
    let directory: URL

    static func openSnapshot(at path: String) throws -> SQLiteReadOnly {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("belauncher-notes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("NoteStore.sqlite")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: path + suffix),
                                              to: directory.appendingPathComponent("NoteStore.sqlite" + suffix))
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else {
            try? FileManager.default.removeItem(at: directory)
            throw CocoaError(.fileReadCorruptFile)
        }
        return SQLiteReadOnly(handle: handle, directory: directory)
    }

    func prepare(_ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        return sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK ? statement : nil
    }

    func close() {
        sqlite3_close_v2(handle)
        try? FileManager.default.removeItem(at: directory)
    }
}
