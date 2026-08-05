import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DatabaseError: Error, CustomStringConvertible {
    case open(String)
    case sql(String, String)

    public var description: String {
        switch self {
        case .open(let m): "Could not open the database: \(m)"
        case .sql(let q, let m): "SQL failed (\(q.prefix(60))): \(m)"
        }
    }
}

public enum SQLValue: Sendable, Equatable {
    case text(String)
    case int(Int64)
    case double(Double)
    case null
}

public struct Row: Sendable {
    private let values: [String: SQLValue]
    init(_ values: [String: SQLValue]) { self.values = values }

    public func string(_ column: String) -> String {
        if case .text(let s) = values[column] ?? .null { return s }
        return ""
    }
    public func int(_ column: String) -> Int64 {
        switch values[column] ?? .null {
        case .int(let i): i
        case .double(let d): Int64(d)
        case .text(let s): Int64(s) ?? 0
        case .null: 0
        }
    }
    public func double(_ column: String) -> Double {
        switch values[column] ?? .null {
        case .double(let d): d
        case .int(let i): Double(i)
        case .text(let s): Double(s) ?? 0
        case .null: 0
        }
    }
}

/// Minimal SQLite wrapper. Main-actor confined: the whole app is a single UI process,
/// so a serial queue or lock would be ceremony with no payoff.
@MainActor
public final class Database {
    // `nonisolated(unsafe)` so `deinit` can close it; it is only ever touched on the main actor.
    private nonisolated(unsafe) var handle: OpaquePointer?

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let db { sqlite3_close_v2(db) }
            throw DatabaseError.open(message)
        }
        handle = db
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA busy_timeout = 3000")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    public func execute(_ sql: String, _ arguments: [SQLValue] = []) throws {
        _ = try perform(sql, arguments, collectRows: false)
    }

    public func query(_ sql: String, _ arguments: [SQLValue] = []) throws -> [Row] {
        try perform(sql, arguments, collectRows: true)
    }

    public var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

    private func perform(_ sql: String, _ arguments: [SQLValue], collectRows: Bool) throws -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.sql(sql, String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in arguments.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(statement, index, s, -1, SQLITE_TRANSIENT)
            case .int(let i): sqlite3_bind_int64(statement, index, i)
            case .double(let d): sqlite3_bind_double(statement, index, d)
            case .null: sqlite3_bind_null(statement, index)
            }
        }

        var rows: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw DatabaseError.sql(sql, String(cString: sqlite3_errmsg(handle)))
            }
            guard collectRows else { continue }
            var values: [String: SQLValue] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(statement, column))
                case SQLITE_NULL: values[name] = .null
                default:
                    if let raw = sqlite3_column_text(statement, column) {
                        values[name] = .text(String(cString: raw))
                    } else {
                        values[name] = .null
                    }
                }
            }
            rows.append(Row(values))
        }
        return rows
    }
}
