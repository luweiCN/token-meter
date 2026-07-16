import Foundation

/// 菜单栏弹窗头部的「今日」汇总（OpenDesign 稿）：大数字 + 按服务商拆分 + 价格未知条数。
/// 口径与 Electron 概览页的 kpis 一致：tokens/成本从 daily_rollup 的今日行聚合，
/// 会话只数主会话（子代理归并进主会话，见 overviewRepository.kpis 的教训）。
public struct MenuBarTodaySummary: Equatable {
    public struct ProviderToday: Equatable {
        public let providerId: String
        public let tokens: Int64
        public let costUsdMicros: Int64
        public let sessions: Int

        public init(providerId: String, tokens: Int64, costUsdMicros: Int64, sessions: Int) {
            self.providerId = providerId
            self.tokens = tokens
            self.costUsdMicros = costUsdMicros
            self.sessions = sessions
        }
    }

    public struct ModelToday: Equatable {
        public let model: String
        public let tokens: Int64
        public let costUsdMicros: Int64

        public init(model: String, tokens: Int64, costUsdMicros: Int64) {
            self.model = model
            self.tokens = tokens
            self.costUsdMicros = costUsdMicros
        }
    }

    public let tokens: Int64
    public let costUsdMicros: Int64
    public let sessions: Int
    public let unknownEvents: Int
    /// 按今日 tokens 降序。
    public let perProvider: [ProviderToday]
    /// 今日按模型（model_canonical，跨 provider 合并），tokens 降序。
    /// 不带会话数——一个会话可以用多个模型，按模型数会话会重复计（既有裁定）。
    public let perModel: [ModelToday]

    public init(
        tokens: Int64,
        costUsdMicros: Int64,
        sessions: Int,
        unknownEvents: Int,
        perProvider: [ProviderToday],
        perModel: [ModelToday] = []
    ) {
        self.tokens = tokens
        self.costUsdMicros = costUsdMicros
        self.sessions = sessions
        self.unknownEvents = unknownEvents
        self.perProvider = perProvider
        self.perModel = perModel
    }

    public static let empty = MenuBarTodaySummary(tokens: 0, costUsdMicros: 0, sessions: 0, unknownEvents: 0, perProvider: [])
}

public enum MenuBarTodaySummaryRepository {
    /// `now` 可注入，测试不必骑在午夜边界上。表不存在（v1 库尚未迁移）时返回 empty，
    /// 绝不能抛 no such table——菜单栏在任何库状态下都要能打开。
    public static func load(from database: SQLiteDatabase, now: Date = Date()) -> MenuBarTodaySummary {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = calendar.timeZone
        let today = formatter.string(from: now)

        guard let usageRows = try? database.query(
            """
            SELECT provider_id AS providerId,
                   coalesce(sum(tokens_input + tokens_output + tokens_cache_read
                                + tokens_cache_write_5m + tokens_cache_write_1h), 0) AS tokens,
                   coalesce(sum(cost_usd_micros), 0) AS cost,
                   coalesce(sum(cost_unknown_events), 0) AS unknown
              FROM daily_rollup
             WHERE usage_date = ?
            GROUP BY provider_id
            """,
            [.text(today)]
        ) else {
            return .empty
        }

        // 口径与 Electron 热力图日详情（overviewRepository.dayModelBreakdown）一致。
        let modelRows = (try? database.query(
            """
            SELECT model_canonical AS model,
                   coalesce(sum(tokens_input + tokens_output + tokens_cache_read
                                + tokens_cache_write_5m + tokens_cache_write_1h), 0) AS tokens,
                   coalesce(sum(cost_usd_micros), 0) AS cost
              FROM daily_rollup
             WHERE usage_date = ?
            GROUP BY model_canonical
            ORDER BY tokens DESC
            """,
            [.text(today)]
        )) ?? []

        let sessionRows = (try? database.query(
            """
            SELECT coalesce(s.provider_id, s.source_kind) AS providerId, count(*) AS n
              FROM session_rollup sr
              JOIN agent_sessions s ON s.id = sr.session_id
             WHERE sr.last_event_epoch_ms >= ?
               AND s.root_session_key IS NULL AND s.status != 'deleted'
            GROUP BY providerId
            """,
            [.int(Int64(dayStart.timeIntervalSince1970 * 1000))]
        )) ?? []

        var sessionsByProvider: [String: Int] = [:]
        for row in sessionRows {
            if let id = row.string("providerId"), let n = row.int("n") {
                sessionsByProvider[id] = Int(n)
            }
        }

        var perProvider: [MenuBarTodaySummary.ProviderToday] = []
        var totalTokens: Int64 = 0
        var totalCost: Int64 = 0
        var totalUnknown = 0
        for row in usageRows {
            guard let id = row.string("providerId") else { continue }
            let tokens = row.int("tokens") ?? 0
            let cost = row.int("cost") ?? 0
            totalTokens += tokens
            totalCost += cost
            totalUnknown += Int(row.int("unknown") ?? 0)
            perProvider.append(.init(
                providerId: id,
                tokens: tokens,
                costUsdMicros: cost,
                sessions: sessionsByProvider[id] ?? 0
            ))
        }
        perProvider.sort { $0.tokens > $1.tokens }

        let perModel: [MenuBarTodaySummary.ModelToday] = modelRows.compactMap { row in
            guard let model = row.string("model") else { return nil }
            return .init(model: model, tokens: row.int("tokens") ?? 0, costUsdMicros: row.int("cost") ?? 0)
        }

        let totalSessions = sessionsByProvider.values.reduce(0, +)
        return MenuBarTodaySummary(
            tokens: totalTokens,
            costUsdMicros: totalCost,
            sessions: totalSessions,
            unknownEvents: totalUnknown,
            perProvider: perProvider,
            perModel: perModel
        )
    }
}
