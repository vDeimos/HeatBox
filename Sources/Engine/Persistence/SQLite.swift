import Foundation
import SQLite3

/// A value in a database row.
enum SQLValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    var string: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var int: Int64? {
        switch self {
        case .integer(let value): return value
        case .real(let value): return Int64(value)
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    static func optional(_ text: String?) -> SQLValue { text.map(SQLValue.text) ?? .null }
    static func optional(_ number: Int64?) -> SQLValue { number.map(SQLValue.integer) ?? .null }
    static func bool(_ value: Bool) -> SQLValue { .integer(value ? 1 : 0) }
}

struct SQLiteError: Error, Equatable {
    let code: Int32
    let message: String
}

/// One open SQLite database. It is the system's own library; the
/// engine links nothing else. Statements take their values as parameters,
/// never as text put into the statement. Each database is owned by one actor,
/// which is what makes handing this object across tasks safe.
final class SQLiteDatabase: @unchecked Sendable {
    private let handle: OpaquePointer
    /// Tells SQLite to copy a bound string before the call returns.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens the file, creating it when it is missing. Nil opens a database in memory.
    init(file: URL?) throws {
        var opened: OpaquePointer?
        let path = file?.path ?? ":memory:"
        let code = sqlite3_open_v2(path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let opened { sqlite3_close(opened) }
            throw SQLiteError(code: code, message: message)
        }
        handle = opened
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit {
        sqlite3_close(handle)
    }

    private func failure() -> SQLiteError {
        SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Runs statements that take no values and return nothing.
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    /// Runs one statement and returns its rows.
    @discardableResult
    func run(_ sql: String, _ values: [SQLValue] = []) throws -> [[SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null: code = sqlite3_bind_null(statement, index)
            case .integer(let number): code = sqlite3_bind_int64(statement, index, number)
            case .real(let number): code = sqlite3_bind_double(statement, index, number)
            case .text(let text): code = sqlite3_bind_text(statement, index, text, -1, Self.transient)
            }
            guard code == SQLITE_OK else { throw failure() }
        }
        var rows: [[SQLValue]] = []
        let columns = sqlite3_column_count(statement)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw failure() }
            var row: [SQLValue] = []
            row.reserveCapacity(Int(columns))
            for column in 0..<columns {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, column)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(statement, column))))
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// Everything `work` does is kept, or none of it.
    func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try work()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// The version number the database carries for its own layout.
    var userVersion: Int {
        get { Int((try? run("PRAGMA user_version"))?.first?.first?.int ?? 0) }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }
}
