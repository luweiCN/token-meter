import Foundation

public final class LocalAgentUsageRepository {
    private let database: SQLiteDatabase
    private let formatter = ISO8601DateFormatter()

    public init(database: SQLiteDatabase) {
        self.database = database
        formatter.formatOptions = [.withInternetDateTime]
    }

    public func upsert(
        _ session: ParsedAgentSession,
        scanRootId: Int64,
        sourceFileId: Int64?,
        runId: Int64?
    ) throws {
        let providerId = providerId(for: session.sourceKind)
        try database.execute("BEGIN IMMEDIATE")
        do {
            let projectId = try upsertProject(session.projectPath)
            try upsertAgentSession(
                session,
                providerId: providerId,
                scanRootId: scanRootId,
                sourceFileId: sourceFileId,
                projectId: projectId,
                runId: runId
            )
            let sessionId = try lookupSessionId(sourceKind: session.sourceKind, sessionKey: session.sessionKey)

            if let usage = session.usage {
                try upsertUsage(usage, session: session, sessionId: sessionId)
                if usage.kind == .cumulativeSessionTotal {
                    try updateLatestUsagePointer(sessionId: sessionId)
                    try refreshDailyRollups(providerId: providerId, sourceKind: session.sourceKind)
                }
            }

            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    private func upsertAgentSession(
        _ session: ParsedAgentSession,
        providerId: String,
        scanRootId: Int64,
        sourceFileId: Int64?,
        projectId: Int64?,
        runId: Int64?
    ) throws {
        try database.execute(
            """
            INSERT INTO agent_sessions(
                source_kind,
                source_session_key,
                scan_root_id,
                source_file_id,
                project_id,
                provider_id,
                model_name,
                cli_version,
                session_started_at,
                session_updated_at,
                cwd_path,
                status,
                source_revision,
                first_seen_run_id,
                last_seen_run_id,
                last_indexed_run_id,
                raw_meta_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?)
            ON CONFLICT(source_kind, source_session_key) DO UPDATE SET
                scan_root_id = excluded.scan_root_id,
                source_file_id = excluded.source_file_id,
                project_id = excluded.project_id,
                provider_id = excluded.provider_id,
                model_name = excluded.model_name,
                cli_version = excluded.cli_version,
                session_started_at = coalesce(agent_sessions.session_started_at, excluded.session_started_at),
                session_updated_at = excluded.session_updated_at,
                cwd_path = excluded.cwd_path,
                status = 'active',
                source_revision = excluded.source_revision,
                last_seen_run_id = excluded.last_seen_run_id,
                last_indexed_run_id = excluded.last_indexed_run_id,
                raw_meta_json = excluded.raw_meta_json
            """,
            [
                .text(session.sourceKind.rawValue),
                .text(session.sessionKey),
                .int(scanRootId),
                sqliteInt(sourceFileId),
                sqliteInt(projectId),
                .text(providerId),
                sqliteText(session.modelName),
                sqliteText(session.cliVersion),
                sqliteText(session.startedAt.map(formatter.string(from:))),
                sqliteText(session.updatedAt.map(formatter.string(from:))),
                sqliteText(session.projectPath),
                .text(sourceRevision(for: session)),
                sqliteInt(runId),
                sqliteInt(runId),
                sqliteInt(runId),
                .text(rawMetaJSON(session.rawMeta))
            ]
        )
    }

    private func upsertProject(_ path: String?) throws -> Int64? {
        guard let path, !path.isEmpty else { return nil }
        let displayName = URL(fileURLWithPath: path).lastPathComponent.isEmpty
            ? path
            : URL(fileURLWithPath: path).lastPathComponent
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

    private func lookupSessionId(sourceKind: SourceKind, sessionKey: String) throws -> Int64 {
        try database.query(
            "SELECT id FROM agent_sessions WHERE source_kind = ? AND source_session_key = ?",
            [.text(sourceKind.rawValue), .text(sessionKey)]
        )[0].int("id") ?? 0
    }

    private func upsertUsage(_ usage: ParsedSessionUsage, session: ParsedAgentSession, sessionId: Int64) throws {
        let usageSeq = Int64(max(session.usageSequence, 1))
        let observedAt = formatter.string(from: session.updatedAt ?? Date())
        if let usageId = try existingUsageId(sessionId: sessionId, usageSeq: usageSeq, sourceOffset: session.sourceOffset, kind: usage.kind) {
            try database.execute(
                """
                UPDATE session_usage SET
                    observed_at = ?,
                    usage_seq = ?,
                    tokens_input = ?,
                    tokens_output = ?,
                    tokens_reasoning = ?,
                    tokens_cache_read = ?,
                    tokens_cache_write = ?,
                    cost_usd_micros = ?,
                    source_offset = ?,
                    is_cumulative = ?
                WHERE id = ?
                """,
                usageParameters(
                    observedAt: observedAt,
                    usageSeq: usageSeq,
                    usage: usage,
                    sourceOffset: session.sourceOffset
                ) + [.int(usage.kind == .cumulativeSessionTotal ? 1 : 0), .int(usageId)]
            )
        } else if let conflictingUsageId = try existingUsageId(sessionId: sessionId, usageSeq: usageSeq, sourceOffset: session.sourceOffset) {
            guard usage.kind == .cumulativeSessionTotal else { return }
            try database.execute(
                """
                UPDATE session_usage SET
                    observed_at = ?,
                    usage_seq = ?,
                    tokens_input = ?,
                    tokens_output = ?,
                    tokens_reasoning = ?,
                    tokens_cache_read = ?,
                    tokens_cache_write = ?,
                    cost_usd_micros = ?,
                    source_offset = ?,
                    is_cumulative = ?
                WHERE id = ?
                """,
                usageParameters(
                    observedAt: observedAt,
                    usageSeq: usageSeq,
                    usage: usage,
                    sourceOffset: session.sourceOffset
                ) + [.int(1), .int(conflictingUsageId)]
            )
        } else {
            try database.execute(
                """
                INSERT INTO session_usage(
                    session_id,
                    observed_at,
                    usage_seq,
                    tokens_input,
                    tokens_output,
                    tokens_reasoning,
                    tokens_cache_read,
                    tokens_cache_write,
                    cost_usd_micros,
                    source_offset,
                    is_cumulative
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.int(sessionId)] + usageParameters(
                    observedAt: observedAt,
                    usageSeq: usageSeq,
                    usage: usage,
                    sourceOffset: session.sourceOffset
                ) + [.int(usage.kind == .cumulativeSessionTotal ? 1 : 0)]
            )
        }
    }

    private func existingUsageId(
        sessionId: Int64,
        usageSeq: Int64,
        sourceOffset: Int64?,
        kind: ParsedSessionUsageKind? = nil
    ) throws -> Int64? {
        let cumulativeValue = kind.map { $0 == .cumulativeSessionTotal ? Int64(1) : Int64(0) }
        if let sourceOffset {
            if let cumulativeValue {
                return try database.query(
                    """
                    SELECT id
                    FROM session_usage
                    WHERE session_id = ? AND (usage_seq = ? OR source_offset = ?) AND is_cumulative = ?
                    ORDER BY CASE WHEN usage_seq = ? THEN 0 ELSE 1 END, id DESC
                    LIMIT 1
                    """,
                    [.int(sessionId), .int(usageSeq), .int(sourceOffset), .int(cumulativeValue), .int(usageSeq)]
                ).first?.int("id")
            }

            return try database.query(
                """
                SELECT id
                FROM session_usage
                WHERE session_id = ? AND (usage_seq = ? OR source_offset = ?)
                ORDER BY CASE WHEN usage_seq = ? THEN 0 ELSE 1 END, id DESC
                LIMIT 1
                """,
                [.int(sessionId), .int(usageSeq), .int(sourceOffset), .int(usageSeq)]
            ).first?.int("id")
        }

        if let cumulativeValue {
            return try database.query(
                """
                SELECT id
                FROM session_usage
                WHERE session_id = ? AND usage_seq = ? AND is_cumulative = ?
                LIMIT 1
                """,
                [.int(sessionId), .int(usageSeq), .int(cumulativeValue)]
            ).first?.int("id")
        }

        return try database.query(
            """
            SELECT id
            FROM session_usage
            WHERE session_id = ? AND usage_seq = ?
            LIMIT 1
            """,
            [.int(sessionId), .int(usageSeq)]
        ).first?.int("id")
    }

    private func updateLatestUsagePointer(sessionId: Int64) throws {
        guard let usageId = try database.query(
            """
            SELECT id
            FROM session_usage
            WHERE session_id = ? AND is_cumulative = 1
            ORDER BY usage_seq DESC, observed_at DESC, id DESC
            LIMIT 1
            """,
            [.int(sessionId)]
        ).first?.int("id") else { return }

        try database.execute(
            """
            INSERT INTO session_usage_latest(session_id, session_usage_id, updated_at)
            VALUES (?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(session_id) DO UPDATE SET
                session_usage_id = excluded.session_usage_id,
                updated_at = CURRENT_TIMESTAMP
            """,
            [.int(sessionId), .int(usageId)]
        )
    }

    private func refreshDailyRollups(providerId: String, sourceKind: SourceKind) throws {
        try database.execute(
            "DELETE FROM provider_daily_usage WHERE provider_id = ? AND source_kind = ?",
            [.text(providerId), .text(sourceKind.rawValue)]
        )
        try database.execute(
            """
            INSERT INTO provider_daily_usage(
                usage_date,
                provider_id,
                project_id,
                source_kind,
                sessions_count,
                tokens_input,
                tokens_output,
                tokens_reasoning,
                tokens_cache_read,
                tokens_cache_write,
                total_cost_usd_micros
            )
            SELECT
                substr(u.observed_at, 1, 10) AS usage_date,
                s.provider_id,
                s.project_id,
                s.source_kind,
                count(*) AS sessions_count,
                coalesce(sum(coalesce(u.tokens_input, 0)), 0) AS tokens_input,
                coalesce(sum(coalesce(u.tokens_output, 0)), 0) AS tokens_output,
                coalesce(sum(coalesce(u.tokens_reasoning, 0)), 0) AS tokens_reasoning,
                coalesce(sum(coalesce(u.tokens_cache_read, 0)), 0) AS tokens_cache_read,
                coalesce(sum(coalesce(u.tokens_cache_write, 0)), 0) AS tokens_cache_write,
                coalesce(sum(coalesce(u.cost_usd_micros, 0)), 0) AS total_cost_usd_micros
            FROM agent_sessions s
            JOIN session_usage_latest latest ON latest.session_id = s.id
            JOIN session_usage u ON u.id = latest.session_usage_id
            WHERE s.provider_id = ? AND s.source_kind = ? AND s.status = 'active'
            GROUP BY usage_date, s.provider_id, s.project_id, s.source_kind
            """,
            [.text(providerId), .text(sourceKind.rawValue)]
        )
    }

    private func usageParameters(
        observedAt: String,
        usageSeq: Int64,
        usage: ParsedSessionUsage,
        sourceOffset: Int64?
    ) -> [SQLiteValue] {
        [
            .text(observedAt),
            .int(usageSeq),
            sqliteInt(usage.inputTokens),
            sqliteInt(usage.outputTokens),
            sqliteInt(usage.reasoningTokens),
            sqliteInt(usage.cacheReadTokens),
            sqliteInt(usage.cacheWriteTokens),
            sqliteInt(usage.costUSDMicros),
            sqliteInt(sourceOffset)
        ]
    }

    private func providerId(for sourceKind: SourceKind) -> String {
        switch sourceKind {
        case .claudeJSONL:
            "claude-code"
        case .codexJSONL:
            "codex"
        case .ompJSONL:
            "omp"
        case .opencodeSQLite:
            "opencode"
        }
    }

    private func sourceRevision(for session: ParsedAgentSession) -> String {
        "\(session.sourceKind.rawValue):\(session.sessionKey):\(max(session.usageSequence, 1)):\(session.sourceOffset ?? -1)"
    }

    private func sqliteInt(_ value: Int64?) -> SQLiteValue {
        value.map(SQLiteValue.int) ?? .null
    }

    private func sqliteText(_ value: String?) -> SQLiteValue {
        value.map(SQLiteValue.text) ?? .null
    }

    private func rawMetaJSON(_ rawMeta: [String: String]) -> String {
        let filtered = rawMeta.filter { key, value in
            !isPrivateRawMeta(key: key, value: value)
        }
        guard JSONSerialization.isValidJSONObject(filtered),
              let data = try? JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func isPrivateRawMeta(key: String, value: String) -> Bool {
        let normalizedKey = key.lowercased()
        let blockedKeyFragments = [
            "prompt",
            "message",
            "content",
            "tool",
            "reasoning",
            "api_key",
            "apikey",
            "key",
            "token",
            "credential",
            "secret",
            "cookie",
            "attachment",
            "response"
        ]
        if blockedKeyFragments.contains(where: normalizedKey.contains) {
            return true
        }

        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedValue.contains("secret")
            || normalizedValue.contains("api key")
            || normalizedValue.hasPrefix("sk-")
            || isPathLikePrivateValue(normalizedValue)
    }

    private func isPathLikePrivateValue(_ normalizedValue: String) -> Bool {
        normalizedValue.hasPrefix("/")
            || normalizedValue.hasPrefix("~/")
            || normalizedValue.contains("file://")
            || normalizedValue.contains(".ssh/")
            || normalizedValue.contains(".aws/")
            || normalizedValue.contains(".config/")
            || normalizedValue.contains(".ssh\\")
            || normalizedValue.contains(".aws\\")
            || normalizedValue.contains(".config\\")
    }
}
