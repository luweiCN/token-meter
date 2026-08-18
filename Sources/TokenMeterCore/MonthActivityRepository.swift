import Foundation

/// 一天的用量聚合（本地时区日）。弹窗头部当月热力图用。
public struct DayActivity: Equatable, Identifiable {
    /// "YYYY-MM-DD"（与 daily_rollup.usage_date 同口径：SQLite localtime）。
    public let date: String
    public let tokens: Int64
    public let costUsdMicros: Int64
    public let sessions: Int
    public let events: Int

    public var id: String { date }

    public init(date: String, tokens: Int64, costUsdMicros: Int64, sessions: Int, events: Int) {
        self.date = date
        self.tokens = tokens
        self.costUsdMicros = costUsdMicros
        self.sessions = sessions
        self.events = events
    }
}

/// 当月每日用量（跨 provider/模型聚合），供弹窗头部热力图使用。
public enum MonthActivityRepository {
    public static func load(
        from database: SQLiteDatabase,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DayActivity] {
        guard let monthStart = calendar.dateInterval(of: .month, for: now)?.start,
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
            return []
        }

        let rows = (try? database.query(
            """
            SELECT usage_date,
                   sum(tokens_input + tokens_output + tokens_reasoning +
                       tokens_cache_read + tokens_cache_write_5m + tokens_cache_write_1h) AS tokens_total,
                   sum(cost_usd_micros) AS cost_total,
                   sum(sessions_count) AS sessions_total,
                   sum(events_count) AS events_total
            FROM daily_rollup
            WHERE usage_date >= ? AND usage_date < ?
            GROUP BY usage_date
            ORDER BY usage_date
            """,
            [.text(dayText(monthStart, calendar: calendar)), .text(dayText(nextMonth, calendar: calendar))]
        )) ?? []

        return rows.map { row in
            DayActivity(
                date: row.string("usage_date") ?? "",
                tokens: row.int("tokens_total") ?? 0,
                costUsdMicros: row.int("cost_total") ?? 0,
                sessions: Int(row.int("sessions_total") ?? 0),
                events: Int(row.int("events_total") ?? 0)
            )
        }
    }

    /// "YYYY-MM-DD"（零填充），与 SQLite `date(..., 'localtime')` 的输出同构。
    public static func dayText(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0, components.month ?? 0, components.day ?? 0
        )
    }
}

/// 某一天的模型用量明细（主界面热力图详情同款）。按 token 降序。
public struct DayModelUsage: Equatable, Identifiable {
    public let model: String
    public let tokens: Int64
    public let costUsdMicros: Int64

    public var id: String { model }

    public init(model: String, tokens: Int64, costUsdMicros: Int64) {
        self.model = model
        self.tokens = tokens
        self.costUsdMicros = costUsdMicros
    }
}

public enum DayModelBreakdownRepository {
    /// 口径与 Electron overviewRepository.dayModelBreakdown 一致（tokens 不含 reasoning）。
    public static func load(
        from database: SQLiteDatabase,
        date: String,
        limit: Int = 6
    ) -> [DayModelUsage] {
        let rows = (try? database.query(
            """
            SELECT model_canonical AS model,
                   coalesce(sum(tokens_input + tokens_output + tokens_cache_read
                                + tokens_cache_write_5m + tokens_cache_write_1h), 0) AS tokens,
                   coalesce(sum(cost_usd_micros), 0) AS cost
              FROM daily_rollup
             WHERE usage_date = ?
            GROUP BY model_canonical
            ORDER BY tokens DESC
            LIMIT ?
            """,
            [.text(date), .int(Int64(limit))]
        )) ?? []

        return rows.map { row in
            DayModelUsage(
                model: row.string("model") ?? "",
                tokens: row.int("tokens") ?? 0,
                costUsdMicros: row.int("cost") ?? 0
            )
        }
    }
}
