import Foundation

public final class LocalAgentScanner {
    private let database: SQLiteDatabase
    private let repository: LocalAgentUsageRepository
    private let isoFormatter = ISO8601DateFormatter()

    public init(database: SQLiteDatabase) {
        self.database = database
        self.repository = LocalAgentUsageRepository(database: database)
    }

    public static func seedDefaultScanRoots(
        database: SQLiteDatabase,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        for root in TokenMeterPaths.defaultScanRoots(homeDirectory: homeDirectory) {
            try database.execute(
                """
                INSERT OR IGNORE INTO scan_roots(kind, root_path, display_name, stable_source_key)
                VALUES (?, ?, ?, ?)
                """,
                [
                    .text(root.kind.rawValue),
                    .text(root.rootURL.path),
                    .text(root.displayName),
                    .text(root.stableSourceKey)
                ]
            )
        }
    }

    public func scanRoot(id rootId: Int64) async throws {
        guard let root = try loadEnabledRoot(id: rootId) else { return }

        let runId = try startRun(
            rootId: root.id,
            runKind: root.runKind,
            cursorBefore: root.lastSuccessfulCursor
        )
        let progress = ScanProgress(cursorAfter: root.lastSuccessfulCursor)

        do {
            switch root.kind {
            case .claudeJSONL, .codexJSONL, .ompJSONL:
                try scanJSONLRoot(root, runId: runId, progress: progress)

            case .opencodeSQLite:
                try scanOpenCodeRoot(root, runId: runId, progress: progress)
            }

            try finishRun(
                rootId: root.id,
                runId: runId,
                status: "ok",
                filesSeen: progress.filesSeen,
                filesChanged: progress.filesChanged,
                bytesRead: progress.bytesRead,
                cursorAfter: progress.cursorAfter,
                errorSummary: nil
            )
        } catch {
            try finishRun(
                rootId: root.id,
                runId: runId,
                status: "partial",
                filesSeen: progress.filesSeen,
                filesChanged: progress.filesChanged,
                bytesRead: progress.bytesRead,
                cursorAfter: progress.cursorAfter,
                errorSummary: sanitizedError(error)
            )
            throw error
        }
    }

    private func loadEnabledRoot(id rootId: Int64) throws -> ScanRoot? {
        let rows = try database.query(
            """
            SELECT id, kind, root_path, source_db_path, scan_mode, last_successful_cursor
            FROM scan_roots
            WHERE id = ? AND enabled = 1 AND scan_mode != 'disabled'
            """,
            [.int(rootId)]
        )
        guard let row = rows.first,
              let id = row.int("id"),
              let kindText = row.string("kind"),
              let kind = SourceKind(rawValue: kindText),
              let rootPath = row.string("root_path") else {
            return nil
        }

        let runKind = row.string("scan_mode") == "full" ? "full" : "incremental"
        return ScanRoot(
            id: id,
            kind: kind,
            rootURL: URL(fileURLWithPath: rootPath, isDirectory: kind != .opencodeSQLite),
            sourceDatabaseURL: row.string("source_db_path").map { URL(fileURLWithPath: $0) },
            runKind: runKind,
            lastSuccessfulCursor: row.string("last_successful_cursor")
        )
    }

    private func scanJSONLRoot(_ root: ScanRoot, runId: Int64, progress: ScanProgress) throws {
        for file in try jsonlFiles(under: root.rootURL) {
            progress.filesSeen += 1
            try scanJSONLFile(file, root: root, runId: runId, progress: progress)
        }
    }

    private func scanJSONLFile(_ file: URL, root: ScanRoot, runId: Int64, progress: ScanProgress) throws {
        let metadata = try fileMetadata(for: file)
        let relativePath = relativePath(for: file, rootURL: root.rootURL)
        let existing = try existingSourceFile(rootId: root.id, relativePath: relativePath)

        if let existing,
           existing.parseStatus == "ok",
           existing.lastParsedRunId != nil,
           existing.sizeBytes == metadata.sizeBytes,
           existing.mtimeNanoseconds == metadata.mtimeNanoseconds {
            try markSourceFileSeen(sourceFileId: existing.id, runId: runId)
            return
        }

        progress.filesChanged += 1
        progress.bytesRead += metadata.sizeBytes

        do {
            let readResult = try JSONLStreamReader.readLines(from: file, startingAt: 0)
            let fileId = try upsertSourceFile(
                rootId: root.id,
                relativePath: relativePath,
                canonicalPath: metadata.canonicalPath,
                fileType: "jsonl_session",
                metadata: metadata,
                runId: runId,
                parsed: true,
                parseStatus: "ok",
                parseError: nil
            )

            if !readResult.lines.isEmpty {
                let parsed = try parser(for: root.kind).parse(lines: readResult.lines, sourceURL: file)
                try repository.upsert(parsed, scanRootId: root.id, sourceFileId: fileId, runId: runId)
            }

            return
        } catch {
            _ = try? upsertSourceFile(
                rootId: root.id,
                relativePath: relativePath,
                canonicalPath: metadata.canonicalPath,
                fileType: "jsonl_session",
                metadata: metadata,
                runId: runId,
                parsed: false,
                parseStatus: "failed",
                parseError: sanitizedError(error)
            )
            throw error
        }
    }

    private func scanOpenCodeRoot(_ root: ScanRoot, runId: Int64, progress: ScanProgress) throws {
        let databaseURL = root.sourceDatabaseURL ?? root.rootURL
        guard fileExists(at: databaseURL) else { return }

        progress.filesSeen = 1

        let metadata = try fileMetadata(for: databaseURL)
        let relativePath = databaseURL.lastPathComponent.isEmpty ? databaseURL.path : databaseURL.lastPathComponent
        let existing = try existingSourceFile(rootId: root.id, relativePath: relativePath)
        let fingerprintChanged = existing?.sizeBytes != metadata.sizeBytes
            || existing?.mtimeNanoseconds != metadata.mtimeNanoseconds

        do {
            let sourceDatabase = try SQLiteDatabase(path: databaseURL.path)
            defer { try? sourceDatabase.close() }
            let sessions = try OpenCodeSessionAdapter(sourceDatabase: sourceDatabase)
                .changedSessions(after: root.lastSuccessfulCursor)

            let fileId = try upsertSourceFile(
                rootId: root.id,
                relativePath: relativePath,
                canonicalPath: metadata.canonicalPath,
                fileType: "sqlite_db",
                metadata: metadata,
                runId: runId,
                parsed: true,
                parseStatus: "ok",
                parseError: nil
            )

            let changed = fingerprintChanged || !sessions.isEmpty
            if changed {
                progress.filesChanged = 1
                progress.bytesRead = metadata.sizeBytes
            }

            for session in sessions {
                try repository.upsert(session, scanRootId: root.id, sourceFileId: fileId, runId: runId)
            }

            progress.cursorAfter = latestCursor(in: sessions) ?? root.lastSuccessfulCursor
        } catch {
            progress.filesChanged = 1
            progress.bytesRead = metadata.sizeBytes
            _ = try? upsertSourceFile(
                rootId: root.id,
                relativePath: relativePath,
                canonicalPath: metadata.canonicalPath,
                fileType: "sqlite_db",
                metadata: metadata,
                runId: runId,
                parsed: false,
                parseStatus: "failed",
                parseError: sanitizedError(error)
            )
            throw error
        }
    }

    private func jsonlFiles(under root: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue {
            return root.pathExtension.lowercased() == "jsonl" ? [root] : []
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return []
        }

        var files: [URL] = []
        for case let file as URL in enumerator where file.pathExtension.lowercased() == "jsonl" {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(file)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func parser(for kind: SourceKind) throws -> LocalAgentSessionParser {
        switch kind {
        case .claudeJSONL:
            ClaudeCodeSessionParser()
        case .codexJSONL:
            CodexSessionParser()
        case .ompJSONL:
            OmpSessionParser()
        case .opencodeSQLite:
            throw LocalAgentParserError.unsupportedFormat
        }
    }

    private func startRun(rootId: Int64, runKind: String, cursorBefore: String?) throws -> Int64 {
        try database.execute(
            """
            INSERT INTO scan_runs(scan_root_id, run_kind, cursor_before)
            VALUES (?, ?, ?)
            """,
            [.int(rootId), .text(runKind), sqliteText(cursorBefore)]
        )
        try database.execute(
            """
            UPDATE scan_roots
            SET last_scan_started_at = CURRENT_TIMESTAMP,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
            """,
            [.int(rootId)]
        )
        return try database.query("SELECT last_insert_rowid() AS id")[0].int("id") ?? 0
    }

    private func finishRun(
        rootId: Int64,
        runId: Int64,
        status: String,
        filesSeen: Int64,
        filesChanged: Int64,
        bytesRead: Int64,
        cursorAfter: String?,
        errorSummary: String?
    ) throws {
        try database.execute(
            """
            UPDATE scan_runs
            SET status = ?,
                finished_at = CURRENT_TIMESTAMP,
                files_seen = ?,
                files_changed = ?,
                bytes_read = ?,
                cursor_after = ?,
                error_summary = ?
            WHERE id = ?
            """,
            [
                .text(status),
                .int(filesSeen),
                .int(filesChanged),
                .int(bytesRead),
                sqliteText(cursorAfter),
                sqliteText(errorSummary),
                .int(runId)
            ]
        )

        if status == "ok" {
            try database.execute(
                """
                UPDATE scan_roots
                SET last_scan_finished_at = CURRENT_TIMESTAMP,
                    last_successful_cursor = COALESCE(?, last_successful_cursor),
                    last_error = NULL,
                    updated_at = CURRENT_TIMESTAMP
                WHERE id = ?
                """,
                [sqliteText(cursorAfter), .int(rootId)]
            )
        } else {
            try database.execute(
                """
                UPDATE scan_roots
                SET last_scan_finished_at = CURRENT_TIMESTAMP,
                    last_error = ?,
                    updated_at = CURRENT_TIMESTAMP
                WHERE id = ?
                """,
                [sqliteText(errorSummary), .int(rootId)]
            )
        }
    }

    private func existingSourceFile(rootId: Int64, relativePath: String) throws -> ExistingSourceFile? {
        guard let row = try database.query(
            """
            SELECT id, size_bytes, mtime_ns, parse_status, last_parsed_run_id
            FROM source_files
            WHERE scan_root_id = ? AND relative_path = ?
            """,
            [.int(rootId), .text(relativePath)]
        ).first,
              let id = row.int("id"),
              let sizeBytes = row.int("size_bytes"),
              let mtimeNanoseconds = row.int("mtime_ns"),
              let parseStatus = row.string("parse_status") else {
            return nil
        }
        return ExistingSourceFile(
            id: id,
            sizeBytes: sizeBytes,
            mtimeNanoseconds: mtimeNanoseconds,
            parseStatus: parseStatus,
            lastParsedRunId: row.int("last_parsed_run_id")
        )
    }

    private func markSourceFileSeen(sourceFileId: Int64, runId: Int64) throws {
        try database.execute(
            """
            UPDATE source_files
            SET last_seen_run_id = ?,
                disappeared_at = NULL,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
            """,
            [.int(runId), .int(sourceFileId)]
        )
    }

    private func upsertSourceFile(
        rootId: Int64,
        relativePath: String,
        canonicalPath: String,
        fileType: String,
        metadata: FileMetadata,
        runId: Int64,
        parsed: Bool,
        parseStatus: String,
        parseError: String?
    ) throws -> Int64 {
        try database.execute(
            """
            INSERT INTO source_files(
                scan_root_id,
                relative_path,
                canonical_path,
                file_type,
                size_bytes,
                mtime_ns,
                inode,
                dev,
                first_seen_run_id,
                last_seen_run_id,
                last_parsed_run_id,
                disappeared_at,
                parse_status,
                parse_error
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
            ON CONFLICT(scan_root_id, relative_path) DO UPDATE SET
                canonical_path = excluded.canonical_path,
                file_type = excluded.file_type,
                size_bytes = excluded.size_bytes,
                mtime_ns = excluded.mtime_ns,
                inode = excluded.inode,
                dev = excluded.dev,
                last_seen_run_id = excluded.last_seen_run_id,
                last_parsed_run_id = excluded.last_parsed_run_id,
                disappeared_at = NULL,
                parse_status = excluded.parse_status,
                parse_error = excluded.parse_error,
                updated_at = CURRENT_TIMESTAMP
            """,
            [
                .int(rootId),
                .text(relativePath),
                .text(canonicalPath),
                .text(fileType),
                .int(metadata.sizeBytes),
                .int(metadata.mtimeNanoseconds),
                sqliteInt(metadata.inode),
                sqliteInt(metadata.dev),
                .int(runId),
                .int(runId),
                parsed ? .int(runId) : .null,
                .text(parseStatus),
                sqliteText(parseError)
            ]
        )
        return try database.query(
            """
            SELECT id
            FROM source_files
            WHERE scan_root_id = ? AND relative_path = ?
            """,
            [.int(rootId), .text(relativePath)]
        )[0].int("id") ?? 0
    }

    private func fileMetadata(for url: URL) throws -> FileMetadata {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let sizeBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modifiedAt = attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        return FileMetadata(
            canonicalPath: url.resolvingSymlinksInPath().path,
            sizeBytes: sizeBytes,
            mtimeNanoseconds: Int64((modifiedAt.timeIntervalSince1970 * 1_000_000_000).rounded()),
            inode: (attributes[.systemFileNumber] as? NSNumber)?.int64Value,
            dev: (attributes[.systemNumber] as? NSNumber)?.int64Value
        )
    }

    private func relativePath(for file: URL, rootURL: URL) -> String {
        let filePath = file.standardizedFileURL.path
        let rootPath = rootURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }
        return file.lastPathComponent.isEmpty ? filePath : file.lastPathComponent
    }

    private func fileExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func latestCursor(in sessions: [ParsedAgentSession]) -> String? {
        guard let latestDate = sessions.compactMap({ $0.updatedAt ?? $0.startedAt }).max() else { return nil }
        return preciseCursor(from: latestDate)
    }

    private func preciseCursor(from date: Date) -> String {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        if milliseconds % 1000 == 0 {
            return isoFormatter.string(from: date)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    private func sanitizedError(_ error: Error) -> String {
        switch error {
        case LocalAgentParserError.missingSessionKey:
            return "parse failed: missing session key"
        case LocalAgentParserError.unsupportedFormat:
            return "parse failed: unsupported format"
        case is SQLiteDatabaseError:
            return "database operation failed"
        case is CocoaError:
            return "file operation failed"
        default:
            return "scan failed"
        }
    }

    private func sqliteInt(_ value: Int64?) -> SQLiteValue {
        value.map(SQLiteValue.int) ?? .null
    }

    private func sqliteText(_ value: String?) -> SQLiteValue {
        value.map(SQLiteValue.text) ?? .null
    }
}

private struct ScanRoot {
    let id: Int64
    let kind: SourceKind
    let rootURL: URL
    let sourceDatabaseURL: URL?
    let runKind: String
    let lastSuccessfulCursor: String?
}

private final class ScanProgress {
    var filesSeen: Int64 = 0
    var filesChanged: Int64 = 0
    var bytesRead: Int64 = 0
    var cursorAfter: String?

    init(cursorAfter: String?) {
        self.cursorAfter = cursorAfter
    }
}


private struct ExistingSourceFile {
    let id: Int64
    let sizeBytes: Int64
    let mtimeNanoseconds: Int64
    let parseStatus: String
    let lastParsedRunId: Int64?
}

private struct FileMetadata {
    let canonicalPath: String
    let sizeBytes: Int64
    let mtimeNanoseconds: Int64
    let inode: Int64?
    let dev: Int64?
}
