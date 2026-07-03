import CSQLite
import Foundation

public enum SQLiteValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
}

public struct SQLiteRow: Equatable {
    private let values: [String: SQLiteValue]

    public init(values: [String: SQLiteValue]) {
        self.values = values
    }

    public func int(_ column: String) -> Int64? {
        if case let .int(value)? = values[column] { return value }
        return nil
    }

    public func string(_ column: String) -> String? {
        if case let .text(value)? = values[column] { return value }
        return nil
    }
}

public final class SQLiteDatabase {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite open failed"
            throw SQLiteDatabaseError.openFailed(message)
        }
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA busy_timeout = 5000")
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    public func close() throws {
        guard let handle else { return }
        let result = sqlite3_close(handle)
        guard result == SQLITE_OK else {
            throw SQLiteDatabaseError.closeFailed(errorMessage)
        }
        self.handle = nil
    }

    public func execute(_ sql: String, _ parameters: [SQLiteValue] = []) throws {
        if parameters.isEmpty {
            var message: UnsafeMutablePointer<CChar>?
            defer { sqlite3_free(message) }
            guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
                throw SQLiteDatabaseError.stepFailed(message.map { String(cString: $0) } ?? errorMessage)
            }
            return
        }

        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else {
                throw SQLiteDatabaseError.stepFailed(errorMessage)
            }
        }
    }

    public func query(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        var rows: [SQLiteRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw SQLiteDatabaseError.stepFailed(errorMessage) }

            var values: [String: SQLiteValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    values[name] = .int(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    values[name] = .double(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    values[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_NULL:
                    values[name] = .null
                default:
                    values[name] = .null
                }
            }
            rows.append(SQLiteRow(values: values))
        }
    }

    private func prepare(_ sql: String, _ parameters: [SQLiteValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteDatabaseError.prepareFailed(errorMessage)
        }
        do {
            for (offset, parameter) in parameters.enumerated() {
                try bind(parameter, to: Int32(offset + 1), statement: statement)
            }
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
        return statement
    }

    private func bind(_ value: SQLiteValue, to index: Int32, statement: OpaquePointer?) throws {
        let result: Int32
        switch value {
        case .null:
            result = sqlite3_bind_null(statement, index)
        case let .int(value):
            result = sqlite3_bind_int64(statement, index, value)
        case let .double(value):
            result = sqlite3_bind_double(statement, index, value)
        case let .text(value):
            result = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        }
        guard result == SQLITE_OK else { throw SQLiteDatabaseError.bindFailed(errorMessage) }
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error"
    }
}

public enum SQLiteDatabaseError: Error, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case bindFailed(String)
    case stepFailed(String)
    case closeFailed(String)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
