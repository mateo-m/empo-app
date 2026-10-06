import CSQLite
import Foundation

/// What SQLite reported, with the message it gave.
public struct SQLiteError: Error, Equatable, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String {
        "SQLite error \(code): \(message)"
    }
}

/// One value a statement binds or reads.
public enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var int64: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    public var double: Double? {
        switch self {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    public var string: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    public var data: Data? {
        if case .blob(let value) = self { return value }
        return nil
    }
}

/// A thin wrapper over the C API, big enough for the state store of
/// SPEC 6.2 and no bigger.
///
/// The binding is the `CSQLite` system-library target of
/// `Package.swift`, a module map over `sqlite3.h`, and not Darwin's
/// `SQLite3` module. `SQLite3` has no Linux twin, and a Darwin-only
/// store would take every test of this file off the Linux runner
/// while the Linux floor in `scripts/run-swift-tests.sh` stayed where
/// it was. Linux CI installs `libsqlite3-dev` for the header.
///
/// The class is not `Sendable`. One database handle belongs to the
/// task that opened it.
public final class SQLiteDatabase {

    private var handle: OpaquePointer?

    /// Opens the file, or an in-memory database when `url` is `nil`.
    public init(url: URL?) throws {
        let path = url?.path ?? ":memory:"
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(handle)
            throw SQLiteError(code: code, message: message)
        }
        self.handle = handle
        // A run touches a few rows and must survive a kill mid-write,
        // per 6.2. The write-ahead log keeps a killed process from
        // leaving a half-written page in the main file, and the
        // synchronous setting still fsyncs at every checkpoint.
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA busy_timeout = 5000")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    public func close() {
        sqlite3_close_v2(handle)
        handle = nil
    }

    /// Runs one or more statements that return no rows.
    public func execute(_ sql: String) throws {
        var raw: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &raw)
        guard code == SQLITE_OK else {
            let message = raw.map { String(cString: $0) } ?? lastMessage
            sqlite3_free(raw)
            throw SQLiteError(code: code, message: message)
        }
        sqlite3_free(raw)
    }

    /// Runs one statement and drops its rows.
    public func run(_ sql: String, _ values: [SQLiteValue] = []) throws {
        _ = try query(sql, values)
    }

    /// Runs one statement and collects every row.
    @discardableResult
    public func query(_ sql: String, _ values: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw SQLiteError(code: prepared, message: lastMessage)
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            try bind(value, at: index, in: statement)
        }

        var rows: [[SQLiteValue]] = []
        let columnCount = Int(sqlite3_column_count(statement))
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLiteError(code: step, message: lastMessage)
            }
            var row: [SQLiteValue] = []
            row.reserveCapacity(columnCount)
            for column in 0..<Int32(columnCount) {
                row.append(read(column: column, in: statement))
            }
            rows.append(row)
        }
        return rows
    }

    /// Runs `body` inside a transaction and rolls back when it
    /// throws. A run must never leave half of a write behind.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var userVersion: Int32 {
        get throws {
            let rows = try query("PRAGMA user_version")
            return Int32(rows.first?.first?.int64 ?? 0)
        }
    }

    public func setUserVersion(_ version: Int32) throws {
        // PRAGMA takes no bound parameter, so the value goes in the
        // text. It is an `Int32` and cannot carry SQL.
        try execute("PRAGMA user_version = \(version)")
    }

    /// The names of every table in the database, sorted.
    public func tableNames() throws -> [String] {
        let rows = try query(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        return rows.compactMap { $0.first?.string }
    }

    // MARK: - Bind and read

    private var lastMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    /// SQLite keeps a pointer to the bound bytes until the statement
    /// finalizes, so every bind here copies. That is what
    /// `SQLITE_TRANSIENT` asks for.
    private static let transient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self)

    private func bind(
        _ value: SQLiteValue, at index: Int32, in statement: OpaquePointer
    ) throws {
        let code: Int32
        switch value {
        case .null:
            code = sqlite3_bind_null(statement, index)
        case .integer(let number):
            code = sqlite3_bind_int64(statement, index, number)
        case .real(let number):
            code = sqlite3_bind_double(statement, index, number)
        case .text(let text):
            code = sqlite3_bind_text(statement, index, text, -1, Self.transient)
        case .blob(let data):
            code = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob64(
                    statement, index, bytes.baseAddress, sqlite3_uint64(data.count),
                    Self.transient)
            }
        }
        guard code == SQLITE_OK else {
            throw SQLiteError(code: code, message: lastMessage)
        }
    }

    private func read(column: Int32, in statement: OpaquePointer) -> SQLiteValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, column))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else {
                return .blob(Data())
            }
            return .blob(Data(bytes: bytes, count: count))
        case SQLITE_NULL:
            return .null
        default:
            guard let text = sqlite3_column_text(statement, column) else { return .null }
            return .text(String(cString: text))
        }
    }
}
