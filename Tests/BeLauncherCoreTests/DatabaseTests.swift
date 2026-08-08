import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Database access modes")
@MainActor
struct DatabaseTests {
    @Test("read-only diagnostics never create a missing database")
    func readOnlyDoesNotCreate() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("beacon-read-only-(UUID().uuidString).sqlite3").path

        #expect(throws: DatabaseError.self) {
            _ = try Database(path: path, readOnly: true)
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("read-only access can inspect an existing database without switching its journal")
    func readOnlyCanInspect() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("beacon-read-only-(UUID().uuidString).sqlite3").path
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }

        let database = try Database(path: path)
        try database.execute("CREATE TABLE sample (value TEXT NOT NULL)")
        try database.execute("INSERT INTO sample VALUES (?)", [.text("ok")])
        _ = database

        let readOnly = try Database(path: path, readOnly: true)
        #expect(try readOnly.query("SELECT value FROM sample").first?.string("value") == "ok")
    }
}
