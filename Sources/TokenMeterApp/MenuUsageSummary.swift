import Foundation
import TokenMeterCore

struct MenuUsagePeriods: Decodable, Equatable {
    let total: DailyUsage
    let month: DailyUsage
    let week: DailyUsage

    static func local(_ stats: OverviewStats) -> Self {
        Self(total: DailyUsage(bucket: stats.total), month: DailyUsage(bucket: stats.month),
             week: DailyUsage(bucket: stats.week))
    }

    func adding(_ other: Self) -> Self? {
        guard let total = total.adding(other.total), let month = month.adding(other.month),
              let week = week.adding(other.week) else { return nil }
        return Self(total: total, month: month, week: week)
    }
}

struct NodeUsageHistory: Decodable, Equatable {
    let periods: MenuUsagePeriods
    let days: [String: NodeUsageDay]

    private enum CodingKeys: String, CodingKey { case days }

    init(from decoder: Decoder) throws {
        periods = try MenuUsagePeriods(from: decoder)
        days = try decoder.container(keyedBy: CodingKeys.self).decode([String: NodeUsageDay].self, forKey: .days)
    }

    func monthActivity(local: [DayActivity], includesLocal: Bool) -> [DayActivity]? {
        let localByDate = Dictionary(uniqueKeysWithValues: local.map { ($0.date, $0) })
        var activity = includesLocal ? [:] : localByDate
        for (date, day) in days {
            let detail = localByDate[date]
            let localUsage = detail.map(DailyUsage.init(activity:)) ?? .zero
            guard let usage = day.usage.adding(includesLocal ? .zero : localUsage) else { return nil }
            let (events, overflow) = day.events.addingReportingOverflow(includesLocal ? 0 : detail?.events ?? 0)
            guard !overflow else { return nil }

            var row = DayActivity(date: date, tokens: usage.tokens, costUsdMicros: usage.costMicros,
                                  sessions: detail?.sessions ?? 0, events: events)
            row.cacheUsage = usage.cacheUsage
            row.costUnknownEvents = usage.unknownCost
            row.tokenUnreportedEvents = usage.unknownTokens
            row.includesAllSessionCounts = !day.sessionsIncomplete && (!includesLocal || day.usage == localUsage)
            activity[date] = row
        }
        return activity.values.sorted { $0.date < $1.date }
    }
}

struct NodeUsageDay: Decodable, Equatable {
    let usage: DailyUsage
    let events: Int
    let sessionsIncomplete: Bool
    let models: [DailyModelSummary.Row]
    let devices: [String: NodeUsageAmount]?

    private enum CodingKeys: String, CodingKey { case events, sessionsIncomplete, models, devices }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        usage = try DailyUsage(from: decoder)
        events = try fields.decode(Int.self, forKey: .events)
        sessionsIncomplete = try fields.decodeIfPresent(Bool.self, forKey: .sessionsIncomplete) ?? false
        models = try fields.decode([DailyModelSummary.Row].self, forKey: .models)
        devices = try fields.decodeIfPresent([String: NodeUsageAmount].self, forKey: .devices)
        guard events >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .events, in: fields, debugDescription: "Invalid event count")
        }
    }
}

struct DayDeviceUsage: Identifiable {
    let id: String
    let name: String
    let usage: DailyUsage
}

struct MenuTodayUsage: Equatable {
    let usage: DailyUsage
    let sessions: Int?

    static let empty = Self(usage: .zero, sessions: 0)

    static func from(node: NodeDailySummary?, local: MenuBarTodaySummary) -> Self {
        let localUsage = DailyUsage(local: local)
        let localSessions = local.sessionCountIsComplete ? local.sessions : nil
        let fallback = Self(usage: localUsage, sessions: localSessions)
        guard let node else { return fallback }
        var totals = node.includesLocal ? DailyUsage.zero : localUsage
        for device in node.devices {
            guard let combined = totals.adding(device.usage) else { return fallback }
            totals = combined
        }
        let sessionsIncomplete = node.history?.days[node.day]?.sessionsIncomplete ??
            node.devices.contains { !$0.local && ($0.active || $0.usage != .zero) }
        return Self(usage: totals, sessions: !sessionsIncomplete && totals == localUsage ? localSessions : nil)
    }
}

extension DailyUsage {
    init(local today: MenuBarTodaySummary) {
        self.init(tokens: today.tokens, unknownTokens: Int64(today.tokenUnreportedEvents),
                  costMicros: today.costUsdMicros, unknownCost: Int64(today.unknownEvents), cacheUsage: today.cacheUsage)
    }

    init(bucket: OverviewStatsBucket) {
        self.init(tokens: bucket.tokens, unknownTokens: bucket.tokenUnreportedEvents,
                  costMicros: bucket.costUsdMicros, unknownCost: bucket.costUnknownEvents, cacheUsage: bucket.cacheUsage)
    }

    init(activity day: DayActivity) {
        self.init(tokens: day.tokens, unknownTokens: day.tokenUnreportedEvents,
                  costMicros: day.costUsdMicros, unknownCost: day.costUnknownEvents, cacheUsage: day.cacheUsage)
    }

    init(local model: DayModelUsage) {
        self.init(tokens: model.tokens, unknownTokens: model.tokenUnreportedEvents,
                  costMicros: model.costUsdMicros, unknownCost: model.costUnknownEvents, cacheUsage: model.cacheUsage)
    }

}
