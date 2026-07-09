import Foundation

/// 把 `ParsedSession` 落库到 schema v2 的 `usage_events` / `agent_sessions` / `projects`。
///
/// 与 v1 的 `LocalAgentUsageRepository` 并存：后者继续喂 scanner、写 v1 表，
/// 直到 Task 14 切换 scanner，Task 18 再删掉 v1 表。这里只做加法，不碰任何旧表。
public final class UsageEventWriter {
    private let database: SQLiteDatabase
    private let costCalculator: CostCalculator
    private let dateFormatter = ISO8601DateFormatter()

    public init(database: SQLiteDatabase, costCalculator: CostCalculator) {
        self.database = database
        self.costCalculator = costCalculator
        dateFormatter.formatOptions = [.withInternetDateTime]
    }

    public func write(_ session: ParsedSession, scanRootId: Int64, sourceFileId: Int64, runId: Int64?) throws {
        try database.execute("BEGIN IMMEDIATE")
        do {
            let projectId = try upsertProject(session.projectPath)
            try upsertAgentSession(session, scanRootId: scanRootId, projectId: projectId, runId: runId)
            let sessionId = try lookupSessionId(sourceKind: session.sourceKind, sessionKey: session.sessionKey)

            for event in UsageEventDeduplicator.deduplicate(session.events) {
                try writeEvent(event, sessionId: sessionId, sourceFileId: sourceFileId)
            }

            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    /// 断点续读的位置按**文件**取。一个 session 横跨父 jsonl 与多个 subagent jsonl，
    /// 各文件的偏移互不相干，绝不能按 session_id 取（会把不同文件的偏移混在一起）。
    public func lastSourceOffset(sourceFileId: Int64) throws -> Int64? {
        try database.query(
            "SELECT max(source_offset) AS max_offset FROM usage_events WHERE source_file_id = ?",
            [.int(sourceFileId)]
        ).first?.int("max_offset")
    }

    // MARK: - Project

    private func upsertProject(_ path: String?) throws -> Int64? {
        guard let path, !path.isEmpty else { return nil }
        let lastComponent = URL(fileURLWithPath: path).lastPathComponent
        let displayName = lastComponent.isEmpty ? path : lastComponent
        try database.execute(
            """
            INSERT INTO projects(project_key, canonical_path, display_name, first_seen_at, last_seen_at)
            VALUES (?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            ON CONFLICT(project_key) DO UPDATE SET
                canonical_path = excluded.canonical_path,
                display_name = excluded.display_name,
                last_seen_at = CURRENT_TIMESTAMP
            """,
            [.text(path), .text(path), .text(displayName)]
        )
        return try database.query("SELECT id FROM projects WHERE project_key = ?", [.text(path)]).first?.int("id")
    }

    // MARK: - Session

    private func providerId(for sourceKind: SourceKind) -> String {
        switch sourceKind {
        case .claudeJSONL: return "claude-code"
        case .codexJSONL: return "codex"
        case .ompJSONL: return "omp"
        case .opencodeSQLite: return "opencode"
        }
    }

    private func upsertAgentSession(_ session: ParsedSession, scanRootId: Int64, projectId: Int64?, runId: Int64?) throws {
        // model_name / source_file_id 是 v1 遗留列，v2 写入路径不填它们，Task 18 会删掉这两列。
        try database.execute(
            """
            INSERT INTO agent_sessions(
                source_kind,
                source_session_key,
                scan_root_id,
                project_id,
                provider_id,
                cli_version,
                session_started_at,
                session_updated_at,
                source_revision,
                first_seen_run_id,
                last_seen_run_id,
                last_indexed_run_id,
                raw_meta_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_kind, source_session_key) DO UPDATE SET
                scan_root_id = excluded.scan_root_id,
                project_id = excluded.project_id,
                provider_id = excluded.provider_id,
                cli_version = excluded.cli_version,
                session_started_at = coalesce(agent_sessions.session_started_at, excluded.session_started_at),
                session_updated_at = excluded.session_updated_at,
                source_revision = excluded.source_revision,
                last_seen_run_id = excluded.last_seen_run_id,
                last_indexed_run_id = excluded.last_indexed_run_id,
                raw_meta_json = excluded.raw_meta_json
            """,
            [
                .text(session.sourceKind.rawValue),
                .text(session.sessionKey),
                .int(scanRootId),
                sqliteInt(projectId),
                .text(providerId(for: session.sourceKind)),
                sqliteText(session.cliVersion),
                sqliteText(session.startedAt.map(dateFormatter.string(from:))),
                sqliteText(session.updatedAt.map(dateFormatter.string(from:))),
                .text("\(session.sourceKind.rawValue):\(session.events.count)"),
                sqliteInt(runId),
                sqliteInt(runId),
                sqliteInt(runId),
                sqliteText(rawMetaJSON(session.rawMeta))
            ]
        )
    }

    private func lookupSessionId(sourceKind: SourceKind, sessionKey: String) throws -> Int64 {
        try database.query(
            "SELECT id FROM agent_sessions WHERE source_kind = ? AND source_session_key = ?",
            [.text(sourceKind.rawValue), .text(sessionKey)]
        )[0].int("id") ?? 0
    }

    private func rawMetaJSON(_ meta: [String: String]) -> String? {
        guard !meta.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: meta) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Events

    private func writeEvent(_ event: UsageEvent, sessionId: Int64, sourceFileId: Int64) throws {
        if let dedupeKey = event.dedupeKey {
            // `idx_usage_dedupe` 是 UNIQUE(session_id, dedupe_key)，`INSERT OR IGNORE`
            // 只能挡住第二次写入，但保留的是**先写入的那条**——扫描顺序（先扫到哪个文件）
            // 与事件的时间顺序无关。这里必须显式查出已有行、比较 observed_epoch_ms，
            // 更晚的新事件绝不能覆盖更早的已有记录；更早的新事件必须替换掉更晚的旧记录。
            let existingRows = try database.query(
                "SELECT id, observed_epoch_ms FROM usage_events WHERE session_id = ? AND dedupe_key = ?",
                [.int(sessionId), .text(dedupeKey)]
            )
            if let existing = existingRows.first, let existingId = existing.int("id") {
                let existingObservedAt = existing.int("observed_epoch_ms") ?? Int64.max
                if existingObservedAt <= event.observedEpochMilliseconds {
                    return
                }
                try database.execute("DELETE FROM usage_events WHERE id = ?", [.int(existingId)])
            }
        }

        let (costMicros, costSource) = costCalculator.cost(for: event)

        // ON CONFLICT(source_file_id, event_seq) DO UPDATE 提供的是**幂等重放**，不是防重复计数：
        // 崩溃恢复（见 LocalAgentScanner 的 I2）会从头全量重读同一文件，重新写出相同的
        // (source_file_id, event_seq)+相同取值，DO UPDATE 让这次重写成为无副作用的覆盖
        // （DO NOTHING 也可；抛错则会把正常恢复变成硬失败）。防重复计数靠的是 resumeOffset
        // 的正确与 parser_state 同步推进——被错误续读重读的行会拿到新 seq，绕过本约束。
        try database.execute(
            """
            INSERT INTO usage_events(
                session_id, source_file_id, event_seq, observed_epoch_ms,
                model_name, model_canonical,
                tokens_input, tokens_output, tokens_reasoning,
                tokens_cache_read, tokens_cache_write_5m, tokens_cache_write_1h,
                cost_usd_micros, cost_source, dedupe_key, source_offset, is_sidechain
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_file_id, event_seq) DO UPDATE SET
                session_id = excluded.session_id,
                observed_epoch_ms = excluded.observed_epoch_ms,
                model_name = excluded.model_name,
                model_canonical = excluded.model_canonical,
                tokens_input = excluded.tokens_input,
                tokens_output = excluded.tokens_output,
                tokens_reasoning = excluded.tokens_reasoning,
                tokens_cache_read = excluded.tokens_cache_read,
                tokens_cache_write_5m = excluded.tokens_cache_write_5m,
                tokens_cache_write_1h = excluded.tokens_cache_write_1h,
                cost_usd_micros = excluded.cost_usd_micros,
                cost_source = excluded.cost_source,
                dedupe_key = excluded.dedupe_key,
                source_offset = excluded.source_offset,
                is_sidechain = excluded.is_sidechain
            """,
            [
                .int(sessionId),
                .int(sourceFileId),
                .int(Int64(event.eventSeq)),
                .int(event.observedEpochMilliseconds),
                sqliteText(event.modelName),
                .text(ModelNameNormalizer.canonical(event.modelName)),
                .int(event.inputTokens),
                .int(event.outputTokens),
                .int(event.reasoningTokens),
                .int(event.cacheReadTokens),
                .int(event.cacheWrite5mTokens),
                .int(event.cacheWrite1hTokens),
                costMicros.map(SQLiteValue.int) ?? .null,
                .text(costSource.rawValue),
                sqliteText(event.dedupeKey),
                .int(event.sourceOffset),
                .int(event.isSidechain ? 1 : 0)
            ]
        )
    }

    // MARK: - Helpers

    private func sqliteInt(_ value: Int64?) -> SQLiteValue {
        value.map(SQLiteValue.int) ?? .null
    }

    private func sqliteText(_ value: String?) -> SQLiteValue {
        value.map(SQLiteValue.text) ?? .null
    }
}
