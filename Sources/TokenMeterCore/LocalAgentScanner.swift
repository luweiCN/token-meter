import Foundation

public final class LocalAgentScanner {
    private let database: SQLiteDatabase
    private let writer: UsageEventWriter
    private let rollupBuilder: RollupBuilder
    private let isoFormatter = ISO8601DateFormatter()

    public init(database: SQLiteDatabase) {
        self.database = database
        // 定价来自随包快照；缺失时退化为空表（成本按 unknown 记，仍能正确落 usage_events）。
        let snapshot = (try? PricingSnapshot.loadBundled())
            ?? PricingSnapshot(snapshotVersion: "unavailable", source: "builtin", models: [:])
        self.writer = UsageEventWriter(database: database, costCalculator: CostCalculator(snapshot: snapshot))
        self.rollupBuilder = RollupBuilder(database: database)
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

        // 两张汇总表是 usage_events 的纯函数投影，扫完整体重建即可。全量重建是幂等的，
        // 多根扫描时每根扫完各重建一次会收敛到同一结果（Task 15 再把它提到"整轮一次"）。
        try rollupBuilder.rebuildAll()
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
                // 每个文件包一层 autoreleasepool：JSONSerialization / FileManager 返回的是
                // autoreleased 的 Foundation 对象，一个大 root（Codex 近 2 万文件、单文件 25 万行）
                // 若不逐文件排干，临时对象会堆到数 GB。
                let hadIssue = try autoreleasepool {
                    try scanJSONLFile(file, root: root, runId: runId, progress: progress)
                }
                if hadIssue {
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

    /// 返回 true 表示该文件解析有问题（残行/失败），调用方据此把整根标记为 partial。
    private func scanJSONLFile(_ file: URL, root: ScanRoot, runId: Int64, progress: ScanProgress) throws -> Bool {
        let metadata = try fileMetadata(for: file)
        let relativePath = relativePath(for: file, rootURL: root.rootURL)
        let existing = try existingSourceFile(rootId: root.id, relativePath: relativePath)

        // 指纹未变、上次已完整解析、且 usage_events 里确实已有该文件的事件 → 跳过，不重读。
        // 最后一条是 v1→v2 升级的关键：v1 把 source_files 全标成了 ok，但 v2 的 usage_events
        // 还是空的；只看 ok 会把每个文件都跳过，导致升级后一条事件都不落。
        if let existing,
           existing.parseStatus == "ok",
           existing.lastParsedRunId != nil,
           existing.sizeBytes == metadata.sizeBytes,
           existing.mtimeNanoseconds == metadata.mtimeNanoseconds,
           try writer.lastSourceOffset(sourceFileId: existing.id) != nil {
            try markSourceFileSeen(sourceFileId: existing.id, runId: runId)
            return false
        }

        progress.filesChanged += 1

        // 续读游标按【文件】取：一个 session 横跨父 jsonl 与多个 subagent jsonl，
        // 各文件偏移互不相干，绝不能按 session_id 取。只有存在旧行时才可能续读，
        // 此时 existing.id 一定有——新文件没有旧事件，续读无从谈起。
        // +1 让 reader 从"上次最后一条事件那一行"的中途开始——那半行解析不出对象、被 parser
        // 跳过，从而既不重复计已记事件，又能读到其后追加的新行。
        let planResume = shouldResume(existing: existing, metadata: metadata)
        let startOffset: Int64
        if planResume, let existingId = existing?.id {
            startOffset = (try writer.lastSourceOffset(sourceFileId: existingId)).map { $0 + 1 } ?? 0
        } else {
            startOffset = 0
        }
        // 只有真正续读（startOffset>0）才把上次的 parser_state 传给 parser；否则全量重读、状态清零。
        let resumeState = startOffset > 0 ? existing?.parserState : nil
        if startOffset == 0, let existingId = existing?.id {
            // 全量重读：清掉这个文件旧的事件，避免"改小/改写"后残留过时行。
            try deleteEvents(sourceFileId: existingId)
        }

        let parser = try makeParser(for: root.kind, resuming: resumeState)
        var sawLine = false
        // Claude 有大量非 session 的辅助文件（skill 注入、hook 日志），它们没有 sessionId 也没有 usage。
        // 用便宜的子串探测区分"辅助文件"(跳过)与"缺 sessionId 的真会话文件"(失败)。
        var sawClaudeUsage = false

        let readResult: JSONLReadResult
        do {
            readResult = try JSONLStreamReader.readLines(
                from: file,
                startingAt: startOffset,
                markers: markers(for: root.kind)
            ) { line in
                sawLine = true
                if root.kind == .claudeJSONL, !sawClaudeUsage, line.text.contains("\"usage\"") {
                    sawClaudeUsage = true
                }
                parser.consume(line)
            }
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
                parserState: existing?.parserState
            )
            throw error
        }

        progress.bytesRead += max(0, readResult.nextOffset - startOffset)

        // 整段读取里一条完整行都没有（reader 的 nextOffset 没前进）却留下了残行：
        // 整个文件就是一条没有换行收尾的不完整行，视为失败（与 v1 的 incompleteLine 一致）。
        // 注意用 nextOffset 而非 sawLine：Codex 的 marker 预筛也会让 sawLine 为 false，
        // 但那种情况 nextOffset 已经越过了那些被过滤的完整行。
        if readResult.nextOffset == startOffset, readResult.residual != nil {
            _ = try? upsertSourceFile(
                rootId: root.id,
                relativePath: relativePath,
                canonicalPath: metadata.canonicalPath,
                fileType: "jsonl_session",
                metadata: metadata,
                runId: runId,
                parsed: false,
                parseStatus: "failed",
                parseError: sanitizedError(LocalAgentParserError.incompleteLine),
                parserState: existing?.parserState
            )
            throw LocalAgentParserError.incompleteLine
        }

        // 没有任何行被投递（空文件，或 Codex 下整文件无 marker 行）：记为 ok，不产生 session。
        guard sawLine else {
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
                parserState: resumeState ?? ParserState()
            )
            return false
        }

        let outcome: (session: ParsedSession, state: ParserState)
        do {
            outcome = try parser.finish(sourceURL: file)
        } catch LocalAgentParserError.missingSessionKey where root.kind == .claudeJSONL && !sawClaudeUsage {
            // Claude 辅助文件：无 sessionId 且无 usage，不是会话——记 ok 并跳过，不把整根拖成 partial。
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
                parserState: resumeState ?? ParserState()
            )
            return false
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
                parserState: existing?.parserState
            )
            throw error
        }

        // 残行（最后一行没有换行符收尾）：解析剩余事件仍写入，但标 partial，让整根变 partial。
        let hasResidual = readResult.residual != nil
        // 先落 source_files（拿到 id，满足 usage_events 的外键），再写事件。
        let fileId = try upsertSourceFile(
            rootId: root.id,
            relativePath: relativePath,
            canonicalPath: metadata.canonicalPath,
            fileType: "jsonl_session",
            metadata: metadata,
            runId: runId,
            parsed: true,
            parseStatus: hasResidual ? "partial" : "ok",
            parseError: hasResidual ? "parse partial: incomplete line" : nil,
            parserState: outcome.state
        )

        do {
            try writer.write(outcome.session, scanRootId: root.id, sourceFileId: fileId, runId: runId)
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
                parserState: existing?.parserState
            )
            throw error
        }
        return hasResidual
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
            let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: sourceDatabase)
                .changedSessions(after: root.lastSuccessfulCursor)

            // .db 本身：只做指纹/解析状态跟踪，事件挂在每个 session 各自的 source_file 上。
            _ = try upsertSourceFile(
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

            // 每个 opencode session 各占一个 source_file：event_seq 每 session 从 1 起，
            // UNIQUE(source_file_id, event_seq) 要求不同 session 落在不同 source_file 上才不撞。
            for session in sessions {
                let sessionFileId = try upsertOpenCodeSessionFile(
                    rootId: root.id,
                    dbRelativePath: relativePath,
                    dbCanonicalPath: metadata.canonicalPath,
                    sessionKey: session.sessionKey,
                    metadata: metadata,
                    runId: runId
                )
                try writer.write(session, scanRootId: root.id, sourceFileId: sessionFileId, runId: runId)
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

    private func makeParser(for kind: SourceKind, resuming state: ParserState?) throws -> UsageEventParser {
        switch kind {
        case .claudeJSONL:
            return ClaudeCodeUsageEventParser(resuming: state)
        case .codexJSONL:
            return CodexUsageEventParser(resuming: state)
        case .ompJSONL:
            return OmpUsageEventParser(resuming: state)
        case .opencodeSQLite:
            throw LocalAgentParserError.unsupportedFormat
        }
    }

    /// 只有 Codex 传 marker。它 3+ GB 的 session 绝大多数是 function_call / function_call_output
    /// 行，一条都不含 token_count / session_meta / turn_context，按原始字节预筛能几乎白跳过它们。
    /// Claude 与 omp 把 sessionId / cwd / version 散落在多种行类型里，固定 marker 过滤会漏掉这些
    /// 元数据，所以返回 nil（不过滤）。
    private func markers(for kind: SourceKind) -> [String]? {
        switch kind {
        case .codexJSONL:
            return ["token_count", "session_meta", "turn_context"]
        case .claudeJSONL, .ompJSONL, .opencodeSQLite:
            return nil
        }
    }

    /// 续读条件：上次 ok、文件变大、且 inode/dev 未变（同一个物理文件被追加，而非改写）。
    private func shouldResume(existing: ExistingSourceFile?, metadata: FileMetadata) -> Bool {
        guard let existing,
              existing.parseStatus == "ok",
              metadata.sizeBytes > existing.sizeBytes,
              existing.inode == metadata.inode,
              existing.dev == metadata.dev else {
            return false
        }
        return true
    }

    private func deleteEvents(sourceFileId: Int64) throws {
        try database.execute("DELETE FROM usage_events WHERE source_file_id = ?", [.int(sourceFileId)])
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

    private func upsertOpenCodeSessionFile(
        rootId: Int64,
        dbRelativePath: String,
        dbCanonicalPath: String,
        sessionKey: String,
        metadata: FileMetadata,
        runId: Int64
    ) throws -> Int64 {
        try upsertSourceFile(
            rootId: rootId,
            relativePath: "\(dbRelativePath)#\(sessionKey)",
            canonicalPath: "\(dbCanonicalPath)#\(sessionKey)",
            fileType: "sqlite_db",
            metadata: metadata,
            runId: runId,
            parsed: true,
            parseStatus: "ok",
            parseError: nil,
            parserState: nil
        )
    }

    @discardableResult
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
        parserState: ParserState?
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

    private func decodeParserState(_ json: String?) -> ParserState? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ParserState.self, from: data)
    }

    private func encodeParserState(_ state: ParserState?) -> String? {
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

    private func latestCursor(in sessions: [ParsedSession]) -> String? {
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
    let parserState: ParserState?
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
