import Foundation

/// 两张汇总表都是 `usage_events` 的纯函数投影，随时可以整体重建。
/// 时区变更后重建即可，不必重扫源文件。
public final class RollupBuilder {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func rebuildAll() throws {
        try database.execute("BEGIN IMMEDIATE")
        do {
            try rebuildDailyRollup()
            try rebuildSessionRollup()
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - daily_rollup

    private func rebuildDailyRollup() throws {
        try database.execute("DELETE FROM daily_rollup")
        try database.execute(
            """
            INSERT INTO daily_rollup(
                usage_date, provider_id, source_kind, project_id, model_canonical,
                sessions_count, events_count,
                tokens_input, tokens_output, tokens_reasoning,
                tokens_cache_read, tokens_cache_write_5m, tokens_cache_write_1h,
                cost_usd_micros, cost_unknown_events
            )
            SELECT
                -- observed_epoch_ms 是 UTC 毫秒，'localtime' 修饰符让 SQLite 把它转换成
                -- 运行机器的本地时区再取日期。不带 'localtime' 就是 UTC 日期，
                -- 会把 UTC+8 用户 00:00-08:00 的活动错记到前一天。
                date(e.observed_epoch_ms / 1000, 'unixepoch', 'localtime') AS usage_date,
                s.provider_id,
                s.source_kind,
                s.project_id,
                e.model_canonical,
                -- 分组维度里含 model_canonical，所以这里的会话数是"该模型在该天"的去重数，
                -- 同一个会话当天用了两个模型就会出现在两行里。因此 sessions_count 不能跨组相加，
                -- 总会话数只能来自 session_rollup 或对 usage_events 做 count(distinct session_id)。
                count(DISTINCT e.session_id) AS sessions_count,
                count(*) AS events_count,
                coalesce(sum(e.tokens_input), 0),
                coalesce(sum(e.tokens_output), 0),
                coalesce(sum(e.tokens_reasoning), 0),
                coalesce(sum(e.tokens_cache_read), 0),
                coalesce(sum(e.tokens_cache_write_5m), 0),
                coalesce(sum(e.tokens_cache_write_1h), 0),
                -- sum() 会静默跳过 cost_usd_micros 为 NULL 的行，所以单看这个数字会
                -- 显得"精确"但其实偏低。cost_unknown_events 记下有多少行未定价，
                -- 让调用方能察觉这个总额不完整。
                coalesce(sum(e.cost_usd_micros), 0),
                sum(CASE WHEN e.cost_source = 'unknown' THEN 1 ELSE 0 END)
            FROM usage_events e
            JOIN agent_sessions s ON s.id = e.session_id
            WHERE s.status != 'deleted'
            GROUP BY usage_date, s.provider_id, s.source_kind, s.project_id, e.model_canonical
            """
        )
    }

    // MARK: - session_rollup

    private func rebuildSessionRollup() throws {
        try database.execute("DELETE FROM session_rollup")
        try database.execute(
            """
            INSERT INTO session_rollup(
                session_id, first_event_epoch_ms, last_event_epoch_ms, events_count,
                tokens_total, cost_usd_micros, cost_unknown_events, primary_model
            )
            SELECT
                e.session_id,
                min(e.observed_epoch_ms),
                max(e.observed_epoch_ms),
                count(*),
                coalesce(sum(e.tokens_total), 0),
                coalesce(sum(e.cost_usd_micros), 0),
                sum(CASE WHEN e.cost_source = 'unknown' THEN 1 ELSE 0 END),
                (
                    -- 该会话内 token 总数最大的模型；按 token 数降序、模型名升序打破平局，
                    -- 保证结果确定，不依赖行的物理顺序。
                    SELECT e2.model_canonical
                    FROM usage_events e2
                    WHERE e2.session_id = e.session_id
                    GROUP BY e2.model_canonical
                    ORDER BY sum(e2.tokens_total) DESC, e2.model_canonical ASC
                    LIMIT 1
                )
            FROM usage_events e
            JOIN agent_sessions s ON s.id = e.session_id
            WHERE s.status != 'deleted'
            GROUP BY e.session_id
            """
        )
    }
}
