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

    public func double(_ column: String) -> Double? {
        if case let .double(value)? = values[column] { return value }
        if case let .int(value)? = values[column] { return Double(value) }
        return nil
    }
}

public final class SQLiteDatabase {
    package let path: String
    private var handle: OpaquePointer?
    private var snapshotDirectory: URL?

    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX
        try open(path, flags: flags)
        try execute("PRAGMA busy_timeout = 5000")
        if readOnly {
            do {
                try execute("PRAGMA schema_version")
            } catch {
                let code = sqlite3_errcode(handle)
                guard code == SQLITE_CANTOPEN || code == SQLITE_READONLY else { throw error }
                try openCheckpointedCopy(of: URL(fileURLWithPath: path), originalError: error)
            }
        }
        try execute("PRAGMA foreign_keys = ON")
    }

    private func open(_ path: String, flags: Int32) throws {
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = errorMessage
            sqlite3_close(handle)
            handle = nil
            throw SQLiteDatabaseError.openFailed(message)
        }
    }

    // macOS 的只读 SQLite 打不开已完成 checkpoint 且没有 WAL 旁文件的数据库。
    // 只对稳定的私有副本使用 immutable。活动 WAL 必须由 SQLite 自行读取。
    private func openCheckpointedCopy(of source: URL, originalError: Error) throws {
        let files = FileManager.default
        func hasJournal() -> Bool {
            files.fileExists(atPath: source.path + "-wal") || files.fileExists(atPath: source.path + "-journal")
        }
        guard !hasJournal() else { throw originalError }
        let sourceFile = try FileHandle(forReadingFrom: source)
        defer { try? sourceFile.close() }
        guard let header = try sourceFile.read(upToCount: 20), header.count == 20,
              header.prefix(16) == Data("SQLite format 3\0".utf8), header[18] == 2, header[19] == 2 else {
            throw originalError
        }
        let before = try files.attributesOfItem(atPath: source.path)
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {
            if snapshotDirectory != directory { try? files.removeItem(at: directory) }
        }
        let copy = directory.appendingPathComponent("snapshot.sqlite")
        try files.copyItem(at: source, to: copy)
        let after = try files.attributesOfItem(atPath: source.path)
        let identity: [FileAttributeKey] = [.systemFileNumber, .size, .modificationDate]
        guard !hasJournal(), identity.allSatisfy({ key in
            (before[key] as? NSObject)?.isEqual(after[key]) == true
        }) else {
            // 有写入方接手时重新读 live 连接，避免把旧的主文件当成最新账本。
            try execute("PRAGMA schema_version")
            return
        }
        try close()
        try open(copy.absoluteString + "?immutable=1", flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX)
        try execute("PRAGMA schema_version")
        snapshotDirectory = directory
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
        if let snapshotDirectory { try? FileManager.default.removeItem(at: snapshotDirectory) }
    }

    public func close() throws {
        guard let handle else { return }
        let result = sqlite3_close(handle)
        guard result == SQLITE_OK else {
            throw SQLiteDatabaseError.closeFailed(errorMessage)
        }
        self.handle = nil
        if let snapshotDirectory {
            try? FileManager.default.removeItem(at: snapshotDirectory)
            self.snapshotDirectory = nil
        }
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

    func executeBatch(_ sql: String, rows: some Sequence<[SQLiteValue]>) throws {
        let statement = try prepare(sql, [])
        defer { sqlite3_finalize(statement) }
        for row in rows {
            guard row.count == Int(sqlite3_bind_parameter_count(statement)) else {
                throw SQLiteDatabaseError.bindFailed("parameter count mismatch")
            }
            try bind(row, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteDatabaseError.stepFailed(errorMessage)
            }
            sqlite3_reset(statement)
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

    /// 逐行消费会话元数据，避免把整库的大 BLOB 同时留在内存中。
    func forEachIndexedBlob(_ sql: String, _ consume: (Int64, Data) throws -> Void) throws {
        let statement = try prepare(sql, [])
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw SQLiteDatabaseError.stepFailed(errorMessage) }
            guard let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 1))
            try consume(sqlite3_column_int64(statement, 0), Data(bytes: bytes, count: count))
        }
    }

    private func prepare(_ sql: String, _ parameters: [SQLiteValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteDatabaseError.prepareFailed(errorMessage)
        }
        do {
            try bind(parameters, to: statement)
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
        return statement
    }

    private func bind(_ parameters: [SQLiteValue], to statement: OpaquePointer?) throws {
        for (offset, parameter) in parameters.enumerated() {
            try bind(parameter, to: Int32(offset + 1), statement: statement)
        }
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
