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
        var failureCount = 0
        for file in try jsonlFiles(under: root.rootURL) {
            progress.filesSeen += 1
            do {
                if try scanJSONLFile(file, root: root, runId: runId, progress: progress) {
                    failureCount += 1
                }
            } catch {
                failureCount += 1
            }
        }

        if failureCount > 0 {
            throw JSONLRootPartialError(failureCount: failureCount)
        }
    }

    private func scanJSONLFile(_ file: URL, root: ScanRoot, runId: Int64, progress: ScanProgress) throws -> Bool {
        let metadata = try fileMetadata(for: file)
        let relativePath = relativePath(for: file, rootURL: root.rootURL)
        let existing = try existingSourceFile(rootId: root.id, relativePath: relativePath)

        if let existing,
           existing.parseStatus == "ok",
           existing.lastParsedRunId != nil,
           existing.sizeBytes == metadata.sizeBytes,
           existing.mtimeNanoseconds == metadata.mtimeNanoseconds,
           existing.parserState?.lastOffset == metadata.sizeBytes {
            try markSourceFileSeen(sourceFileId: existing.id, runId: runId)
            return false
        }

        let previousState = existing?.parserState
        let startOffset = jsonlStartOffset(existing: existing, metadata: metadata, previousState: previousState)
        progress.filesChanged += 1

        do {
            let streamParser = try streamingParser(for: root.kind)
            var deliveredLines = 0
            var malformedLineCount = 0
            var hasClaudeSessionIdentifier = false
            var hasClaudeUsageRecord = false
            let readResult = try JSONLStreamReader.readLines(from: file, startingAt: startOffset) { line in
                if let object = JSONDictionary.object(from: line.text) {
                    if root.kind == .claudeJSONL {
                        hasClaudeSessionIdentifier = hasClaudeSessionIdentifier || self.hasAnyString(in: object, keys: ["sessionId", "session_id", "leafUuid", "leaf_uuid"])
                        if let message = JSONDictionary.dictionary(object, "message"),
                           JSONDictionary.dictionary(message, "usage") != nil {
                            hasClaudeUsageRecord = true
                        }
                    }
                } else {
                    malformedLineCount += 1
                }
                deliveredLines += 1
                streamParser.consume(line)
            }
            progress.bytesRead += max(0, readResult.nextOffset - startOffset)
            if deliveredLines == 0, readResult.residual != nil {
                throw LocalAgentParserError.incompleteLine
            }
            let hasResidualLine = readResult.residual != nil
            let residualParseError = hasResidualLine ? "parse partial: incomplete line" : nil
            let parseError = malformedLineCount > 0 ? "parse partial: malformed JSONL lines" : residualParseError

            if root.kind == .claudeJSONL,
               deliveredLines > 0,
               parseError == nil,
               !hasClaudeSessionIdentifier,
               !hasClaudeUsageRecord {
                _ = try upsertSourceFile(
                    rootId: root.id,
                    relativePath: relativePath,
                    canonicalPath: metadata.canonicalPath,
                    fileType: "jsonl_session",
                    metadata: metadata,
                    runId: runId,
                    parsed: true,
                    parseStatus: "ok",
                    parseError: nil,
                    parserState: jsonlParserState(previous: nil, parsed: nil, nextOffset: readResult.nextOffset)
                )
                return false
            }
            let didResume = startOffset > 0
            let previousStateForParse = didResume ? previousState : nil
            let parsedSession: ParsedAgentSession?
            if deliveredLines == 0 {
                parsedSession = nil
            } else {
                let parsed = try streamParser.finish(sourceURL: file)
                parsedSession = merge(
                    parsed,
                    with: previousStateForParse,
                    sourceKind: root.kind,
                    didResume: didResume,
                    codexUsageIsCumulative: streamParser.latestTokenUsageIsCumulative
                )
            }

            let nextState = jsonlParserState(
                previous: previousStateForParse,
                parsed: parsedSession,
                nextOffset: readResult.nextOffset
            )
            let fileId = try upsertSourceFile(
                rootId: root.id,
                relativePath: relativePath,
                canonicalPath: metadata.canonicalPath,
                fileType: "jsonl_session",
                metadata: metadata,
                runId: runId,
                parsed: true,
                parseStatus: parseError == nil ? "ok" : "partial",
                parseError: parseError,
                parserState: nextState
            )

            if let parsedSession {
                try repository.upsert(parsedSession, scanRootId: root.id, sourceFileId: fileId, runId: runId)
            }

            return parseError != nil
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
                parseError: sanitizedError(error),
                parserState: previousState
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
                parseError: nil,
                parserState: nil
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
                parseError: sanitizedError(error),
                parserState: nil
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

    private func streamingParser(for kind: SourceKind) throws -> LocalAgentSessionStreamingParser {
        switch kind {
        case .claudeJSONL:
            ClaudeCodeStreamingParser()
        case .codexJSONL:
            CodexStreamingParser()
        case .ompJSONL:
            OmpStreamingParser()
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
            SELECT id, size_bytes, mtime_ns, inode, dev, parser_state, parse_status, last_parsed_run_id
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
            inode: row.int("inode"),
            dev: row.int("dev"),
            parserState: decodeParserState(row.string("parser_state")),
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
        parseError: String?,
        parserState: JSONLParserState?
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
                parse_error,
                parser_state
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?)
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
                parser_state = excluded.parser_state,
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
                sqliteText(parseError),
                sqliteText(encodeParserState(parserState))
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

    private func jsonlStartOffset(existing: ExistingSourceFile?, metadata: FileMetadata, previousState: JSONLParserState?) -> Int64 {
        guard let existing,
              existing.parseStatus == "ok",
              let previousState,
              previousState.lastOffset == existing.sizeBytes,
              metadata.sizeBytes > existing.sizeBytes,
              existing.inode == metadata.inode,
              existing.dev == metadata.dev else {
            return 0
        }
        return previousState.lastOffset
    }

    private func jsonlParserState(previous: JSONLParserState?, parsed: ParsedAgentSession?, nextOffset: Int64) -> JSONLParserState {
        JSONLParserState(
            lastOffset: nextOffset,
            sessionKey: parsed?.sessionKey ?? previous?.sessionKey,
            projectPath: parsed?.projectPath ?? previous?.projectPath,
            modelName: retainedModelName(parsed: parsed, previous: previous),
            cliVersion: parsed?.cliVersion ?? previous?.cliVersion,
            startedAt: parsed?.startedAt ?? previous?.startedAt,
            updatedAt: parsed?.updatedAt ?? previous?.updatedAt,
            lastUsageSeq: parsed?.usage == nil ? (previous?.lastUsageSeq ?? 0) : parsed?.usageSequence ?? previous?.lastUsageSeq ?? 0,
            lastUsage: parsed?.usage ?? previous?.lastUsage
        )
    }

    private func merge(
        _ parsed: ParsedAgentSession,
        with state: JSONLParserState?,
        sourceKind: SourceKind,
        didResume: Bool,
        codexUsageIsCumulative: Bool
    ) -> ParsedAgentSession {
        guard didResume, let state else { return parsed }
        let usage = mergedUsage(parsed.usage, previous: state.lastUsage, sourceKind: sourceKind, codexUsageIsCumulative: codexUsageIsCumulative)
        let usageSequence = usage == nil ? state.lastUsageSeq : state.lastUsageSeq + parsed.usageSequence
        return ParsedAgentSession(
            sourceKind: parsed.sourceKind,
            sessionKey: state.sessionKey ?? parsed.sessionKey,
            projectPath: parsed.projectPath ?? state.projectPath,
            modelName: retainedModelName(parsed: parsed, previous: state),
            cliVersion: parsed.cliVersion ?? state.cliVersion,
            startedAt: parsed.startedAt ?? state.startedAt,
            updatedAt: parsed.updatedAt ?? state.updatedAt,
            usage: usage,
            usageSequence: usageSequence,
            sourceOffset: parsed.sourceOffset,
            rawMeta: parsed.rawMeta
        )
    }
    private func retainedModelName(parsed: ParsedAgentSession?, previous: JSONLParserState?) -> String? {
        guard let parsed else { return previous?.modelName }
        guard let parsedModel = parsed.modelName else { return previous?.modelName }
        if parsed.sourceKind == .codexJSONL, parsedModel == "gpt-5" {
            return previous?.modelName ?? parsedModel
        }
        return parsedModel
    }


    private func mergedUsage(
        _ usage: ParsedSessionUsage?,
        previous: ParsedSessionUsage?,
        sourceKind: SourceKind,
        codexUsageIsCumulative: Bool
    ) -> ParsedSessionUsage? {
        guard let usage else { return nil }
        if codexUsageIsCumulative, sourceKind == .codexJSONL, usage == previous { return nil }
        guard sourceKind == .claudeJSONL || sourceKind == .ompJSONL, let previous else { return usage }
        return ParsedSessionUsage(
            inputTokens: add(previous.inputTokens, usage.inputTokens),
            outputTokens: add(previous.outputTokens, usage.outputTokens),
            reasoningTokens: add(previous.reasoningTokens, usage.reasoningTokens),
            cacheReadTokens: add(previous.cacheReadTokens, usage.cacheReadTokens),
            cacheWriteTokens: add(previous.cacheWriteTokens, usage.cacheWriteTokens),
            costUSDMicros: add(previous.costUSDMicros, usage.costUSDMicros)
        )
    }

    private func codexUsageIsCumulative(in lines: [JSONLLine]) -> Bool {
        var latestTokenCountIsCumulative = false
        for line in lines {
            guard let object = JSONDictionary.object(from: line.text),
                  JSONDictionary.string(object, "type") == "event_msg",
                  let payload = JSONDictionary.dictionary(object, "payload"),
                  JSONDictionary.string(payload, "type") == "token_count",
                  let info = JSONDictionary.dictionary(payload, "info") else {
                continue
            }
            if JSONDictionary.dictionary(info, "total_token_usage") != nil {
                latestTokenCountIsCumulative = true
            } else if JSONDictionary.dictionary(info, "last_token_usage") != nil {
                latestTokenCountIsCumulative = false
            }
        }
        return latestTokenCountIsCumulative
    }

    private func hasAnyString(in object: [String: Any], keys: [String]) -> Bool {
        keys.contains { JSONDictionary.string(object, $0) != nil }
    }

    private func add(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        guard lhs != nil || rhs != nil else { return nil }
        return (lhs ?? 0) + (rhs ?? 0)
    }

    private func decodeParserState(_ json: String?) -> JSONLParserState? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONLParserState.self, from: data)
    }

    private func encodeParserState(_ state: JSONLParserState?) -> String? {
        guard let state,
              let data = try? JSONEncoder().encode(state) else { return nil }
        return String(decoding: data, as: UTF8.self)
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
        case LocalAgentParserError.incompleteLine:
            return "parse failed: incomplete line"
        case is JSONLRootPartialError:
            return "scan partial: one or more files failed"
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

private struct JSONLRootPartialError: Error {
    let failureCount: Int
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
    let inode: Int64?
    let dev: Int64?
    let parserState: JSONLParserState?
    let parseStatus: String
    let lastParsedRunId: Int64?
}

private struct JSONLParserState: Codable {
    let lastOffset: Int64
    let sessionKey: String?
    let projectPath: String?
    let modelName: String?
    let cliVersion: String?
    let startedAt: Date?
    let updatedAt: Date?
    let lastUsageSeq: Int
    let lastUsage: ParsedSessionUsage?
}

private struct FileMetadata {
    let canonicalPath: String
    let sizeBytes: Int64
    let mtimeNanoseconds: Int64
    let inode: Int64?
    let dev: Int64?
}
