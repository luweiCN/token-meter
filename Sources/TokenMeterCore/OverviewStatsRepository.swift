import Foundation

/// 单个统计桶：token 与花费口径和 Electron 概览页 kpis 完全一致
/// （tokens 不含 reasoning；成本含 unknown 条数）。
public struct OverviewStatsBucket: Equatable {
    public let tokens: Int64
    public let costUsdMicros: Int64
    public let costUnknownEvents: Int64

    public init(tokens: Int64, costUsdMicros: Int64, costUnknownEvents: Int64) {
        self.tokens = tokens
        self.costUsdMicros = costUsdMicros
        self.costUnknownEvents = costUnknownEvents
    }

    public static let zero = OverviewStatsBucket(tokens: 0, costUsdMicros: 0, costUnknownEvents: 0)
}

/// 主界面四指标卡中的三个（总计/当月/本周）。今日卡片菜单栏已有（顶部今日汇总），
/// 不重复搬。口径复刻 Electron overviewRepository.kpis：本周＝周一起、当月＝本月前缀。
public struct OverviewStats: Equatable {
    public let total: OverviewStatsBucket
    public let month: OverviewStatsBucket
    public let week: OverviewStatsBucket
    public let totalSessions: Int

    public init(total: OverviewStatsBucket, month: OverviewStatsBucket, week: OverviewStatsBucket, totalSessions: Int) {
        self.total = total
        self.month = month
        self.week = week
        self.totalSessions = totalSessions
    }

    public static let empty = OverviewStats(
        total: .zero, month: .zero, week: .zero, totalSessions: 0
    )
}

public enum OverviewStatsRepository {
    public static func load(
        from database: SQLiteDatabase,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> OverviewStats {
        let today = MonthActivityRepository.dayText(now, calendar: calendar)
        let monthPrefix = String(today.prefix(7)) + "-%"

        // 本周＝周一起：与 Electron 的 SQLite `date(?, 'weekday 0', '-6 days')` 同一日历，
        // 不自己按 weekday 算，避免周一/周日边界两处漂移。
        let weekStartRow = (try? database.query(
            "SELECT date(?, 'weekday 0', '-6 days') AS d",
            [.text(today)]
        ))?.first
        let weekStart = weekStartRow?.string("d") ?? today

        let select = """
            SELECT coalesce(sum(tokens_input + tokens_output + tokens_cache_read
                                + tokens_cache_write_5m + tokens_cache_write_1h), 0) AS tokens,
                   coalesce(sum(cost_usd_micros), 0) AS cost,
                   coalesce(sum(cost_unknown_events), 0) AS unknown
              FROM daily_rollup
        """

        func bucket(_ sql: String, _ params: [SQLiteValue]) -> OverviewStatsBucket {
            guard let row = (try? database.query(sql, params))?.first else { return .zero }
            return OverviewStatsBucket(
                tokens: row.int("tokens") ?? 0,
                costUsdMicros: row.int("cost") ?? 0,
                costUnknownEvents: row.int("unknown") ?? 0
            )
        }

        let total = bucket(select, [])
        let month = bucket(select + " WHERE usage_date LIKE ?", [.text(monthPrefix)])
        let week = bucket(select + " WHERE usage_date >= ?", [.text(weekStart)])

        // 会话只数主会话（子代理归并进主会话），与今日会话数同口径。
        let sessionsRow = (try? database.query(
            """
            SELECT count(*) AS n FROM session_rollup sr
              JOIN agent_sessions s ON s.id = sr.session_id
             WHERE s.root_session_key IS NULL AND s.status != 'deleted'
            """
        ))?.first
        let totalSessions = Int(sessionsRow?.int("n") ?? 0)

        return OverviewStats(
            total: total,
            month: month,
            week: week,
            totalSessions: totalSessions
        )
    }
}
