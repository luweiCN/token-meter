import CryptoKit
import Foundation

public final class LocalAgentScanner {
    private let database: SQLiteDatabase
    private let writer: UsageEventWriter
    private let rollupBuilder: RollupBuilder
    private let isoFormatter = ISO8601DateFormatter()
    private let scanLock = NSLock()

    /// 测试用 seam：在事件写入（step 2）之后、游标推进（step 3）之前调用。
    /// 让测试能模拟"事件已落库、游标尚未推进"的硬崩溃——抛错即中止，跳过 step 3。
    /// 生产环境永远为 nil。
    var testHookAfterEventWrite: ((Int64) throws -> Void)?

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
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        for root in TokenMeterPaths.defaultScanRoots(homeDirectory: homeDirectory, environment: environment) {
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
        try withExclusiveScan {
            try scan(rootId: rootId, reporter: nil)
        }
    }

    /// 用户显式触发的数据库重建。保留配置，清空所有会话派生数据，再逐根重读原始日志。
    ///
    /// **刻意不包在一个事务里**：真实数据下要跑数分钟、写 27 万行，长写事务会把整个库锁死，
    /// 且 WAL 会膨胀到明细表大小。安全性由自愈保证——删除前先废弃全部解析状态与根游标，
    /// 之后无论在哪一步崩溃，下一次增量扫描都会把当前原始日志完整补回。
    /// `testInterruptedFullRescanSelfHealsOnNextIncrementalScan` 钉住这一点。
    public func fullRescan(onProgress: @escaping (ScanProgressEvent) -> Void = { _ in }) throws {
        try withExclusiveScan {
            try rebuildDatabase(onProgress: onProgress)
        }
    }

    private func rebuildDatabase(onProgress: @escaping (ScanProgressEvent) -> Void) throws {
        // 先废弃所有续读状态，再开始删除数据。这样任一后续语句或扫描中断，下一次普通扫描
        // 也会从原始日志完整补回；不能先删事件再清游标，否则两步之间崩溃会留下空库和旧游标。
        try database.execute("UPDATE source_files SET parser_state = NULL, parse_status = 'pending', parse_error = NULL")
        try database.execute(TokenMeterDatabaseSchema.resetScanState)

        try database.execute("DELETE FROM daily_rollup")
        try database.execute("DELETE FROM session_rollup")
        try database.execute("DELETE FROM daily_active_sessions")
        try database.execute("DELETE FROM usage_events")
        try database.execute("DELETE FROM agent_sessions")
        try database.execute("DELETE FROM projects")
        try database.execute("DELETE FROM source_files")
        try database.execute("DELETE FROM scan_runs")

        let rootIds = try loadEnabledRootIds()
        let totals = try corpusTotals(rootIds: rootIds)
        let reporter = FullRescanProgress(filesTotal: totals.files, bytesTotal: totals.bytes, onProgress: onProgress)

        // 单根解析失败按 scan_runs 记为 partial（与增量路径一致），不因一根出错而中止整轮重扫。
        for rootId in rootIds {
            try? scan(rootId: rootId, reporter: reporter)
        }
        // 末尾一条必发，否则 UI 停在 99.x%。
        reporter.finish()
    }

    private func withExclusiveScan<T>(_ operation: () throws -> T) throws -> T {
        guard scanLock.try() else { throw LocalAgentScannerError.scanAlreadyInProgress }
        defer { scanLock.unlock() }
        return try operation()
    }

    private func scan(rootId: Int64, reporter: FullRescanProgress?) throws {
        guard let root = try loadEnabledRoot(id: rootId) else { return }
        reporter?.currentRoot = root.displayName

        let runId = try startRun(
            rootId: root.id,
            runKind: root.runKind,
            cursorBefore: root.lastSuccessfulCursor
        )
        let progress = ScanProgress(cursorAfter: root.lastSuccessfulCursor)

        do {
            switch root.kind {
            case .claudeJSONL, .codexJSONL, .ompJSONL:
                try scanJSONLRoot(root, runId: runId, progress: progress, reporter: reporter)

            case .opencodeSQLite:
                try scanOpenCodeRoot(root, runId: runId, progress: progress, reporter: reporter)
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
        try writer.flattenRootSessionKeys()
        try rollupBuilder.rebuildAll()
    }

    private func loadEnabledRoot(id rootId: Int64) throws -> ScanRoot? {
        let rows = try database.query(
            """
            SELECT id, kind, root_path, source_db_path, scan_mode, last_successful_cursor, display_name
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
            lastSuccessfulCursor: row.string("last_successful_cursor"),
            displayName: row.string("display_name") ?? kind.rawValue
        )
    }

    private func loadEnabledRootIds() throws -> [Int64] {
        try database.query(
            "SELECT id FROM scan_roots WHERE enabled = 1 AND scan_mode != 'disabled' ORDER BY id"
        ).compactMap { $0.int("id") }
    }

    /// 全量重扫前统计要处理的文件数与总字节，供进度条用。多做一遍目录枚举 + stat，
    /// 相对一次动辄数分钟的重扫可忽略。文件不可读时字节按 0 计，不让统计本身失败。
    private func corpusTotals(rootIds: [Int64]) throws -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        for rootId in rootIds {
            guard let root = try loadEnabledRoot(id: rootId) else { continue }
            switch root.kind {
            case .claudeJSONL, .codexJSONL, .ompJSONL:
                for file in try jsonlFiles(under: root.rootURL) {
                    files += 1
                    bytes += (try? fileMetadata(for: file).sizeBytes) ?? 0
                }
            case .opencodeSQLite:
                let databaseURL = root.sourceDatabaseURL ?? root.rootURL
                if fileExists(at: databaseURL) {
                    files += 1
                    bytes += (try? fileMetadata(for: databaseURL).sizeBytes) ?? 0
                }
            }
        }
        return (files, bytes)
    }

    private func scanJSONLRoot(_ root: ScanRoot, runId: Int64, progress: ScanProgress, reporter: FullRescanProgress?) throws {
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
            // 进度按字节推进：无论跳过还是重读，走完一个文件就把它的大小计入。
            // 仅在全量重扫（reporter 非 nil）时多做一次 stat；增量路径不付这个代价。
            if let reporter {
                reporter.advance(bytes: (try? fileMetadata(for: file).sizeBytes) ?? 0)
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

        // 上次已完整解析（ok）、size 与 mtime 均未变、且已有 v2 的 parser_state → 跳过，不重读。
        // parser_state 非 nil 兼作 v1→v2 升级判据：v1 行的 parser_state 是旧格式，解不成 v2 的
        // ParserState（decodeParserState 返回 nil）→ 不跳过 → 重读补上 v2 事件与游标。
        //
        // 这里【不】做指纹校验，是刻意的取舍：指纹要打开文件读 4 KB 再哈希，而本进程常驻、每分钟
        // 自动刷新，跳过路径上给每个文件都开一次（~2 万次/分钟）只为发现"什么都没变"，代价过高。
        // 代价是：一次**同时**保持精确字节长度【和】mtime_ns 不变的原地改写会被误跳过、其数字将
        // 一直陈旧到下次全量重扫。我们接受它——检测它要给每文件每次扫描加一次 open，而向 session
        // 日志追加的东西没有一个会这么改写。改写风险真正致命的是【续读】路径（把新字节接到旧解析
        // 状态与旧会话身份上），那条路只对"变大的"文件跑，指纹校验留在 shouldResume 里守住。
        if let existing,
           existing.parseStatus == "ok",
           existing.sizeBytes == metadata.sizeBytes,
           existing.mtimeNanoseconds == metadata.mtimeNanoseconds,
           existing.parserState != nil {
            try markSourceFileSeen(sourceFileId: existing.id, runId: runId)
            return false
        }

        progress.filesChanged += 1

        // 续读起点取上次 readLines 停下的字节位置（parser_state.resumeOffset），按【文件】保存：
        // 一个 session 横跨父 jsonl 与多个 subagent jsonl，各文件偏移互不相干。
        // 绝不能用 max(source_offset)+1：source_offset 是行首字节，加一落在行内——今天靠半行
        // JSON 解析失败侥幸不重复，但以空白开头的行残片仍是合法 JSON，会被重复消费并造成重复计数。
        let planResume = shouldResume(existing: existing, metadata: metadata, file: file)
        let startOffset: Int64 = planResume ? (existing?.parserState?.resumeOffset ?? 0) : 0
        // 只有真正续读（startOffset>0）才把上次的 parser_state 传给 parser；否则全量重读、状态清零。
        let resumeState = startOffset > 0 ? existing?.parserState : nil
        if startOffset == 0, let existingId = existing?.id {
            // 全量重读：清掉这个文件旧的事件，避免"改小/改写"后残留过时行。
            try deleteEvents(sourceFileId: existingId)
        }

        let parser = try makeParser(for: root.kind, resuming: resumeState)
        var sawLine = false

        let readResult: JSONLReadResult
        do {
            readResult = try JSONLStreamReader.readLines(
                from: file,
                startingAt: startOffset,
                markers: markers(for: root.kind)
            ) { line in
                sawLine = true
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
                parserState: resumed(resumeState ?? ParserState(), stoppedAt: readResult.nextOffset)
            )
            return false
        }

        let outcome: (session: ParsedSession?, state: ParserState)
        do {
            outcome = try parser.finish(sourceURL: file)
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

        // parser 判定这不是一个会话文件（如 Claude 辅助文件：无 sessionId 且从未见过 usage 对象）：
        // 无事件可写，记 ok 并跳过，不把整根拖成 partial。
        guard let session = outcome.session else {
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
                parserState: resumed(outcome.state, stoppedAt: readResult.nextOffset)
            )
            return false
        }

        // 残行（最后一行没有换行符收尾）：解析剩余事件仍写入，但标 partial，让整根变 partial。
        let hasResidual = readResult.residual != nil

        // I2 三步走，让游标永远不早于它所描述的事件提交：
        // step 1：建/取行为 pending（不推进游标），拿到 id 满足 usage_events 外键。
        let fileId = try beginSourceFile(
            rootId: root.id,
            relativePath: relativePath,
            canonicalPath: metadata.canonicalPath,
            fileType: "jsonl_session",
            metadata: metadata,
            runId: runId
        )

        // step 2：写事件（各自事务提交）。
        do {
            // omp 的子代理靠文件路径关联根主会话（文件内容不带父引用）；其余家在 parser
            // 内已填 ParsedSession.rootSessionKey，这里 override 为 nil、不覆盖。
            let ompAttribution = root.kind == .ompJSONL
                ? OmpUsageEventParser.subagentAttribution(relativePath: relativePath)
                : (rootSessionKey: nil, label: nil)
            try writer.write(session, scanRootId: root.id, sourceFileId: fileId, runId: runId,
                             rootSessionKeyOverride: ompAttribution.rootSessionKey,
                             subagentLabelOverride: ompAttribution.label)
            // Claude 子代理不改解析归属（事件仍归父会话、标 is_sidechain），只把边车里的
            // agentType 名字记到本文件的 source_files.subagent_label，供下钻展示。
            if let label = claudeSubagentLabel(for: file, relativePath: relativePath, kind: root.kind) {
                try setSourceFileSubagentLabel(fileId: fileId, label: label)
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

        // 崩在这一行之前（step 3 未跑）→ 行仍是 pending + 旧游标 → 下次全量重读恢复。
        try testHookAfterEventWrite?(fileId)

        // step 3：单独一条语句推进游标并置 ok/partial。
        try finishSourceFile(
            fileId: fileId,
            file: file,
            metadata: metadata,
            parseStatus: hasResidual ? "partial" : "ok",
            parseError: hasResidual ? "parse partial: incomplete line" : nil,
            parserState: resumed(outcome.state, stoppedAt: readResult.nextOffset),
            runId: runId
        )
        return hasResidual
    }

    private func scanOpenCodeRoot(_ root: ScanRoot, runId: Int64, progress: ScanProgress, reporter: FullRescanProgress?) throws {
        let databaseURL = root.sourceDatabaseURL ?? root.rootURL
        guard fileExists(at: databaseURL) else { return }

        progress.filesSeen = 1

        let metadata = try fileMetadata(for: databaseURL)
        let storageRevision = openCodeStorageRevision(for: databaseURL)
        reporter?.advance(bytes: metadata.sizeBytes)
        let relativePath = databaseURL.lastPathComponent.isEmpty ? databaseURL.path : databaseURL.lastPathComponent
        let existing = try existingSourceFile(rootId: root.id, relativePath: relativePath)
        let fingerprintChanged = existing?.sizeBytes != metadata.sizeBytes
            || existing?.mtimeNanoseconds != metadata.mtimeNanoseconds

        do {
            let sourceDatabase = try SQLiteDatabase(path: databaseURL.path)
            defer { try? sourceDatabase.close() }
            let adapter = OpenCodeUsageEventAdapter(sourceDatabase: sourceDatabase)
            // OpenCode 使用 WAL：主 .db 的 stat 不变时，消息仍可能已新增、更新或删除。
            // 主库 + WAL 的版本只要变化就完整替换快照；未变化则无需扫描万级消息。
            let forceSnapshot = fingerprintChanged
                || existing?.parseStatus != "ok"
                || existing?.parserState?.openCodeStorageRevision != storageRevision

            guard forceSnapshot else {
                if let existing {
                    try markSourceFileSeen(sourceFileId: existing.id, runId: runId)
                }
                progress.cursorAfter = root.lastSuccessfulCursor
                return
            }
            let sessions = try adapter.snapshot()

            progress.filesChanged = 1
            progress.bytesRead = metadata.sizeBytes

            // 主 .db 行充当 crash-safety sentinel：先置 pending，再清旧快照并逐 session 写入；
            // 任一步失败，下次扫描看到非 ok 会再次全量替换，不会把半份快照永久当成完成。
            let databaseFileId = try beginSourceFile(
                rootId: root.id,
                relativePath: relativePath,
                canonicalPath: metadata.canonicalPath,
                fileType: "sqlite_db",
                metadata: metadata,
                runId: runId
            )
            try deleteEvents(scanRootId: root.id)

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

            try finishSourceFile(
                fileId: databaseFileId,
                file: databaseURL,
                metadata: metadata,
                parseStatus: "ok",
                parseError: nil,
                parserState: ParserState(openCodeStorageRevision: storageRevision),
                runId: runId
            )

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
            return ["token_count", "session_meta", "turn_context", "task_started"]
        case .claudeJSONL, .ompJSONL, .opencodeSQLite:
            return nil
        }
    }

    /// 续读条件：上次 ok、文件变大、inode/dev 未变、且**旧记录的前缀在新文件里原样还在**。
    ///
    /// 最后一条不可少：同 inode + 更大 size 既可能是"纯追加"，也可能是"原地改写成更大的内容"
    /// （Data.write 非原子，改写保留 inode）。少了它，改写会被误当追加：新的开头永不被解析、
    /// 旧内容的事件也不会被 deleteEvents 清掉、parser 还带着旧会话身份续读，全乱套。
    /// oldPrefixIntact 拿【旧】len 去读【新】文件比 hash：不变 = 追加 → 续读；变了 = 改写 → 全量重读。
    private func shouldResume(existing: ExistingSourceFile?, metadata: FileMetadata, file: URL) -> Bool {
        guard let existing,
              existing.parseStatus == "ok",
              existing.parserState?.requiresFullReplay != true,
              metadata.sizeBytes > existing.sizeBytes,
              existing.inode == metadata.inode,
              existing.dev == metadata.dev,
              oldPrefixIntact(existing: existing, file: file, currentSize: metadata.sizeBytes) else {
            return false
        }
        return true
    }

    private func deleteEvents(sourceFileId: Int64) throws {
        try database.execute("DELETE FROM usage_events WHERE source_file_id = ?", [.int(sourceFileId)])
    }

    private func deleteEvents(scanRootId: Int64) throws {
        try database.execute(
            "DELETE FROM usage_events WHERE source_file_id IN (SELECT id FROM source_files WHERE scan_root_id = ?)",
            [.int(scanRootId)]
        )
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
            SELECT id, size_bytes, mtime_ns, inode, dev, content_fingerprint, parser_state, parse_status, last_parsed_run_id
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
            contentFingerprint: row.string("content_fingerprint"),
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

    /// I2 step 1：确保 source_files 行存在、拿到 id，并置为 pending。
    ///
    /// 崩溃安全靠的只有一件事：`parse_status='pending'`。skip 与 shouldResume 都要求 'ok'，
    /// 所以只要还是 pending，下次扫描必定全量重读、deleteEvents 清掉写了一半的事件，从头重来。
    /// 这里【碰不到】游标：`beginSourceFile` 根本不接受 parser_state 参数，resumeOffset 无从推进；
    /// 新行 INSERT 的 size/mtime 是否"当前"也无所谓——pending 已经保证它会被重读。
    /// content_fingerprint 留空，由 step 3 的 finishSourceFile 在文件读完后一并算好写入。
    private func beginSourceFile(
        rootId: Int64,
        relativePath: String,
        canonicalPath: String,
        fileType: String,
        metadata: FileMetadata,
        runId: Int64
    ) throws -> Int64 {
        try database.execute(
            """
            INSERT INTO source_files(
                scan_root_id, relative_path, canonical_path, file_type,
                size_bytes, mtime_ns, inode, dev,
                first_seen_run_id, last_seen_run_id, last_parsed_run_id, disappeared_at, parse_status
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, 'pending')
            ON CONFLICT(scan_root_id, relative_path) DO UPDATE SET
                last_seen_run_id = excluded.last_seen_run_id,
                disappeared_at = NULL,
                parse_status = 'pending',
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
                .int(runId)
            ]
        )
        return try database.query(
            "SELECT id FROM source_files WHERE scan_root_id = ? AND relative_path = ?",
            [.int(rootId), .text(relativePath)]
        )[0].int("id") ?? 0
    }

    /// I2 step 3：事件已提交后，单独一条语句推进游标（size/mtime/fingerprint/parser_state）并置 ok/partial。
    /// 指纹在这里按需计算（文件刚被完整读过，多读 4 KB 是噪声），只有真正落地成 ok 的文件才有指纹。
    private func finishSourceFile(
        fileId: Int64,
        file: URL,
        metadata: FileMetadata,
        parseStatus: String,
        parseError: String?,
        parserState: ParserState?,
        runId: Int64
    ) throws {
        try database.execute(
            """
            UPDATE source_files SET
                size_bytes = ?,
                mtime_ns = ?,
                inode = ?,
                dev = ?,
                content_fingerprint = ?,
                parser_state = ?,
                parse_status = ?,
                parse_error = ?,
                last_parsed_run_id = ?,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
            """,
            [
                .int(metadata.sizeBytes),
                .int(metadata.mtimeNanoseconds),
                sqliteInt(metadata.inode),
                sqliteInt(metadata.dev),
                sqliteText(contentFingerprint(for: file, sizeBytes: metadata.sizeBytes)),
                sqliteText(encodeParserState(parserState)),
                .text(parseStatus),
                sqliteText(parseError),
                .int(runId),
                .int(fileId)
            ]
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

    /// 把这次 readLines 停下的字节位置写进要保存的 parser_state，作为下次续读起点。
    private func resumed(_ state: ParserState, stoppedAt offset: Int64) -> ParserState {
        var next = state
        next.resumeOffset = offset
        return next
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

    /// 纯 stat：只取 size/mtime/inode/dev，绝不打开文件。指纹是 I/O 不是属性，不放这里——
    /// 否则常驻扫描每分钟会给每个文件平白开一次。指纹只在真正需要它的 shouldResume / finishSourceFile
    /// 里按需计算。
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

    /// 不读取消息内容，只记录 SQLite 主库和 WAL 的存储版本。OpenCode 的正常写入若尚未
    /// checkpoint，只会改变 `-wal`；只看主库 stat 会把删除/更新误判为“无变化”。
    private func openCodeStorageRevision(for databaseURL: URL) -> String {
        [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal")]
            .map { url in
                guard let metadata = try? fileMetadata(for: url) else { return "missing" }
                return [
                    String(metadata.sizeBytes),
                    String(metadata.mtimeNanoseconds),
                    metadata.inode.map(String.init) ?? "",
                    metadata.dev.map(String.init) ?? ""
                ].joined(separator: ":")
            }
            .joined(separator: "|")
    }

    /// 存进 source_files 的内容指纹，格式 `"<len>:<sha256hex>"`：
    /// len = min(4096, size) 是取样字节数，hash 是前 len 字节的摘要。
    ///
    /// 只哈希开头：真正的追加永不改动开头字节。**len 必须随 hash 一起存**——续读判定要拿
    /// 【旧记录的】len 去读【新文件】的前 len 字节再比（见 oldPrefixIntact）。若改用新文件大小
    /// 重新取样，每次追加都会换取样窗口，追加就永远被误判成改写。
    /// 绝不能为"省一次读"把范围扩大到整文件：那会让 3 GB 的文件每次扫描都从头哈希一遍。
    /// 用有界读取（read(upToCount:)），不要把整文件读进内存。
    private func contentFingerprint(for url: URL, sizeBytes: Int64) -> String? {
        let length = Int(min(4096, max(0, sizeBytes)))
        guard let hash = hashPrefix(of: url, length: length) else { return nil }
        return "\(length):\(hash)"
    }

    private func hashPrefix(of url: URL, length: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = length > 0 ? ((try? handle.read(upToCount: length)) ?? Data()) : Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func parseFingerprint(_ fingerprint: String) -> (length: Int, hash: String)? {
        // length <= 0 必须拒绝：`Int("-5")` 能解析，而负长度会让 oldPrefixIntact 的
        // `currentSize >= length` 恒真、`hashPrefix(length:)` 哈希空串，于是 "-N:<空串哈希>"
        // 对任何新内容都匹配成功、放行续读。指纹的整个职责就是 fail closed，这里必须挡住它。
        guard let colon = fingerprint.firstIndex(of: ":"),
              let length = Int(fingerprint[..<colon]),
              length > 0 else { return nil }
        return (length, String(fingerprint[fingerprint.index(after: colon)...]))
    }

    /// 旧记录的前缀是否在新文件里原样保留 —— 即"这是纯追加而非改写"。
    ///
    /// 缺指纹（读不出，或该行早于指纹功能）一律返回 false（fail closed）：
    /// Optional 的 `nil == nil` 为 true，若直接比 `existing == metadata` 会在读不出指纹时反而放行，
    /// 让一个无法评估的安全检查默默通过。这里用 `guard let` 把每一种"取不到值"都收敛成"不续读"。
    private func oldPrefixIntact(existing: ExistingSourceFile, file: URL, currentSize: Int64) -> Bool {
        guard let fingerprint = existing.contentFingerprint,
              let (oldLength, oldHash) = parseFingerprint(fingerprint),
              currentSize >= Int64(oldLength),
              let newHash = hashPrefix(of: file, length: oldLength) else {
            return false
        }
        return newHash == oldHash
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

    /// Claude 子代理文件（路径含 /subagents/）的同名 .meta.json 里读 agentType，作为子代理名字。
    /// 非 Claude 子代理文件、或边车缺失/读不出 → nil（不阻断扫描）。
    private func claudeSubagentLabel(for file: URL, relativePath: String, kind: SourceKind) -> String? {
        guard kind == .claudeJSONL, relativePath.contains("/subagents/") else { return nil }
        let sidecar = file.deletingPathExtension().appendingPathExtension("meta.json")
        guard let data = try? Data(contentsOf: sidecar),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return JSONDictionary.string(object, "agentType")
    }

    private func setSourceFileSubagentLabel(fileId: Int64, label: String) throws {
        try database.execute(
            "UPDATE source_files SET subagent_label = ? WHERE id = ?",
            [.text(label), .int(fileId)]
        )
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

enum LocalAgentScannerError: Error, Equatable {
    case scanAlreadyInProgress
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
    let displayName: String
}

/// 全量重扫的进度累加器：跨所有 root 累计 filesDone/bytesDone，经 ScanProgressThrottle 节流后
/// 回调 onProgress。每处理完一个文件调 advance，全部跑完调 finish 强发末尾一条。
private final class FullRescanProgress {
    let filesTotal: Int
    let bytesTotal: Int64
    var currentRoot = ""
    private var filesDone = 0
    private var bytesDone: Int64 = 0
    private var throttle = ScanProgressThrottle()
    private let onProgress: (ScanProgressEvent) -> Void

    init(filesTotal: Int, bytesTotal: Int64, onProgress: @escaping (ScanProgressEvent) -> Void) {
        self.filesTotal = filesTotal
        self.bytesTotal = bytesTotal
        self.onProgress = onProgress
    }

    func advance(bytes: Int64) {
        filesDone += 1
        bytesDone += bytes
        emit(isFinal: false)
    }

    func finish() {
        emit(isFinal: true)
    }

    private func emit(isFinal: Bool) {
        guard throttle.shouldEmit(bytesDone: bytesDone, bytesTotal: bytesTotal, isFinal: isFinal) else { return }
        onProgress(ScanProgressEvent(
            filesTotal: filesTotal,
            filesDone: filesDone,
            bytesTotal: bytesTotal,
            bytesDone: bytesDone,
            currentRoot: currentRoot
        ))
    }
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
    let contentFingerprint: String?
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
