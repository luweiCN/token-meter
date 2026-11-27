import Foundation

/// 菜单栏弹窗头部的「今日」汇总（OpenDesign 稿）：大数字 + 按服务商拆分 + 价格未知条数。
/// Token 与费用涵盖当天全部用量。会话数按用户可见主会话去重。
public struct MenuBarTodaySummary: Equatable {
    public struct ProviderToday: Equatable {
        package var cacheUsage = PromptCacheUsage()
        package var unknownCostEvents = 0
        package var sessionCountIsComplete = true
        package var knownSessionCount: Int? { sessionCountIsComplete ? sessions : nil }
        public let providerId: String
        public let tokens: Int64
        public let tokenUnreportedEvents: Int
        public let costUsdMicros: Int64
        public let creditsPicos: Int64
        public let creditEvents: Int
        public let sessions: Int

        public init(
            providerId: String,
            tokens: Int64,
            tokenUnreportedEvents: Int = 0,
            costUsdMicros: Int64,
            creditsPicos: Int64 = 0,
            creditEvents: Int = 0,
            sessions: Int
        ) {
            self.providerId = providerId
            self.tokens = tokens
            self.tokenUnreportedEvents = tokenUnreportedEvents
            self.costUsdMicros = costUsdMicros
            self.creditsPicos = creditsPicos
            self.creditEvents = creditEvents
            self.sessions = sessions
        }
    }

    public struct ModelToday: Equatable {
        package var cacheUsage = PromptCacheUsage()
        package var unknownCostEvents = 0
        package var hasCredits = false
        public let model: String
        public let tokens: Int64
        public let tokenUnreportedEvents: Int
        public let costUsdMicros: Int64

        public init(model: String, tokens: Int64, tokenUnreportedEvents: Int = 0, costUsdMicros: Int64) {
            self.model = model
            self.tokens = tokens
            self.tokenUnreportedEvents = tokenUnreportedEvents
            self.costUsdMicros = costUsdMicros
        }
    }

    public let tokens: Int64
    public let tokenUnreportedEvents: Int
    public let costUsdMicros: Int64
    public let sessions: Int
    public let unknownEvents: Int
    /// 按今日 tokens 降序。
    public let perProvider: [ProviderToday]
    /// 今日按模型（model_canonical，跨 provider 合并），tokens 降序。
    /// 不带会话数——一个会话可以用多个模型，按模型数会话会重复计（既有裁定）。
    public let perModel: [ModelToday]

    package var sessionCountIsComplete: Bool { perProvider.allSatisfy(\.sessionCountIsComplete) }

    package var cacheUsage: PromptCacheUsage {
        perModel.reduce(PromptCacheUsage()) { $0 + $1.cacheUsage }
    }

    public init(
        tokens: Int64,
        tokenUnreportedEvents: Int = 0,
        costUsdMicros: Int64,
        sessions: Int,
        unknownEvents: Int,
        perProvider: [ProviderToday],
        perModel: [ModelToday] = []
    ) {
        self.tokens = tokens
        self.tokenUnreportedEvents = tokenUnreportedEvents
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
                   coalesce(sum(cost_unknown_events), 0) AS unknown,
                   coalesce(sum(token_unreported_events), 0) AS tokenUnreported,
                   coalesce(sum(credits_picos), 0) AS credits,
                   coalesce(sum(credit_events), 0) AS creditEvents,
                   \(PromptCacheUsage.aggregateColumns)
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
            SELECT model_canonical AS model, \(PromptCacheUsage.aggregateColumns),
                   coalesce(sum(tokens_input + tokens_output + tokens_cache_read
                                + tokens_cache_write_5m + tokens_cache_write_1h), 0) AS tokens,
                   coalesce(sum(cost_usd_micros), 0) AS cost,
                   coalesce(sum(cost_unknown_events), 0) AS unknown,
                   coalesce(sum(token_unreported_events), 0) AS tokenUnreported,
                   coalesce(max(credits_picos), 0) > 0 AS hasCredits
              FROM daily_rollup
             WHERE usage_date = ?
            GROUP BY model_canonical
            ORDER BY tokens DESC
            """,
            [.text(today)]
        )) ?? []

        let antigravity = SourceKind.antigravitySQLite.defaultProviderId
        let sessionRows = try? database.query(
            """
            SELECT provider_id AS providerId, count(*) AS n
              FROM daily_active_sessions
             WHERE usage_date = ? AND provider_id != ?
             GROUP BY provider_id
            """,
            [.text(today), .text(antigravity)]
        )

        var sessionsByProvider: [String: Int] = [:]
        for row in sessionRows ?? [] {
            if let id = row.string("providerId"), let n = row.int("n") {
                sessionsByProvider[id] = Int(n)
            }
        }

        var perProvider: [MenuBarTodaySummary.ProviderToday] = []
        var totalTokens: Int64 = 0
        var totalCost: Int64 = 0
        var totalUnknown = 0
        var totalTokenUnreported = 0
        for row in usageRows {
            guard let id = row.string("providerId") else { continue }
            let tokens = row.int("tokens") ?? 0
            let cost = row.int("cost") ?? 0
            totalTokens += tokens
            totalCost += cost
            totalUnknown += Int(row.int("unknown") ?? 0)
            totalTokenUnreported += Int(row.int("tokenUnreported") ?? 0)
            let sessions: Int?
            if id == antigravity {
                sessions = calendar.dateInterval(of: .day, for: now).flatMap { antigravitySessions(in: database, day: $0) }
            } else {
                sessions = sessionRows == nil ? nil : sessionsByProvider[id] ?? 0
            }
            var provider = MenuBarTodaySummary.ProviderToday(
                providerId: id,
                tokens: tokens,
                tokenUnreportedEvents: Int(row.int("tokenUnreported") ?? 0),
                costUsdMicros: cost,
                creditsPicos: row.int("credits") ?? 0,
                creditEvents: Int(row.int("creditEvents") ?? 0),
                sessions: sessions ?? 0
            )
            provider.sessionCountIsComplete = sessions != nil
            provider.cacheUsage = PromptCacheUsage(row: row)
            provider.unknownCostEvents = Int(row.int("unknown") ?? 0)
            perProvider.append(provider)
        }
        perProvider.sort { $0.tokens > $1.tokens }

        let perModel: [MenuBarTodaySummary.ModelToday] = modelRows.compactMap { row in
            guard let model = row.string("model") else { return nil }
            var result = MenuBarTodaySummary.ModelToday(
                model: model,
                tokens: row.int("tokens") ?? 0,
                tokenUnreportedEvents: Int(row.int("tokenUnreported") ?? 0),
                costUsdMicros: row.int("cost") ?? 0
            )
            result.cacheUsage = PromptCacheUsage(row: row)
            result.unknownCostEvents = Int(row.int("unknown") ?? 0)
            result.hasCredits = row.int("hasCredits") == 1
            return result
        }

        let totalSessions = perProvider.compactMap(\.knownSessionCount).reduce(0, +)
        return MenuBarTodaySummary(
            tokens: totalTokens,
            tokenUnreportedEvents: totalTokenUnreported,
            costUsdMicros: totalCost,
            sessions: totalSessions,
            unknownEvents: totalUnknown,
            perProvider: perProvider,
            perModel: perModel
        )
    }

    private static func antigravitySessions(in database: SQLiteDatabase, day: DateInterval) -> Int? {
        guard let rows = try? database.query(
            """
            SELECT s.source_session_key AS sessionKey, r.root_path AS scanRootPath
              FROM agent_sessions s
              LEFT JOIN scan_roots r ON r.id = s.scan_root_id
             WHERE s.provider_id = ? AND s.status != 'deleted'
               AND EXISTS (SELECT 1 FROM usage_events e
                            WHERE e.session_id = s.id AND e.observed_epoch_ms >= ? AND e.observed_epoch_ms < ?)
            """,
            [.text(SourceKind.antigravitySQLite.defaultProviderId), .int(Int64(day.start.timeIntervalSince1970 * 1000)),
             .int(Int64(day.end.timeIntervalSince1970 * 1000))]
        ), !rows.isEmpty else { return nil }
        return AntigravityCLIUsage.topLevelSessionCount(rows.map {
            (sessionKey: $0.string("sessionKey") ?? "", scanRootPath: $0.string("scanRootPath") ?? "")
        })
    }
}
