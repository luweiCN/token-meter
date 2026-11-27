import Foundation
import TokenMeterCore

private func sumCounts(_ first: Int64, _ second: Int64) -> Int64? {
    guard first >= 0, second >= 0 else { return nil }
    let (total, overflow) = first.addingReportingOverflow(second)
    return overflow ? nil : total
}

struct DailyUsage: Equatable, Decodable {
    let tokens: Int64
    let unknownTokens: Int64
    let costMicros: Int64
    let unknownCost: Int64
    let cacheUsage: PromptCacheUsage

    static let zero = DailyUsage(tokens: 0, unknownTokens: 0, costMicros: 0, unknownCost: 0, cacheUsage: .init())

    init(tokens: Int64, unknownTokens: Int64, costMicros: Int64, unknownCost: Int64, cacheUsage: PromptCacheUsage) {
        self.tokens = tokens
        self.unknownTokens = unknownTokens
        self.costMicros = costMicros
        self.unknownCost = unknownCost
        self.cacheUsage = cacheUsage
    }

    private enum CodingKeys: String, CodingKey {
        case tokens, unknownTokens, costMicros, unknownCost, input, cacheRead, cacheWrite
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let tokens = try values.decode(Int64.self, forKey: .tokens)
        let unknownTokens = try values.decode(Int64.self, forKey: .unknownTokens)
        let costMicros = try values.decode(Int64.self, forKey: .costMicros)
        let unknownCost = try values.decode(Int64.self, forKey: .unknownCost)
        let input = try values.decode(Int64.self, forKey: .input)
        let read = try values.decode(Int64.self, forKey: .cacheRead)
        let write = try values.decode(Int64.self, forKey: .cacheWrite)
        guard let partial = sumCounts(input, read), let prompt = sumCounts(partial, write),
              tokens >= prompt, unknownTokens >= 0, costMicros >= 0, unknownCost >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .tokens, in: values, debugDescription: "Invalid daily usage counts")
        }
        self.init(tokens: tokens, unknownTokens: unknownTokens, costMicros: costMicros,
                  unknownCost: unknownCost, cacheUsage: PromptCacheUsage(readTokens: read, inputTokens: prompt))
    }

    init(local row: MenuBarTodaySummary.ProviderToday) {
        self.init(tokens: row.tokens, unknownTokens: Int64(row.tokenUnreportedEvents), costMicros: row.costUsdMicros,
                  unknownCost: Int64(row.unknownCostEvents), cacheUsage: row.cacheUsage)
    }

    var tokenAmount: PopoverTokenAmount { PopoverTokenAmount(tokens: tokens, unreportedEvents: unknownTokens) }

    func hasUsage(hasCredits: Bool) -> Bool {
        self != .zero || hasCredits
    }

    func formattedCost(currency: DisplayCurrency, usdToCny: Double) -> String {
        if unknownCost > 0 && costMicros == 0 { return "未知" }
        return MenuBarNumberFormat.money(costMicros, currency: currency, usdToCny: usdToCny) + (unknownCost > 0 ? "+" : "")
    }

    func adding(_ other: Self) -> Self? {
        guard let tokens = sumCounts(tokens, other.tokens), let missingTokens = sumCounts(unknownTokens, other.unknownTokens),
              let cost = sumCounts(costMicros, other.costMicros), let missingCost = sumCounts(unknownCost, other.unknownCost),
              let read = sumCounts(cacheUsage.readTokens, other.cacheUsage.readTokens),
              let prompt = sumCounts(cacheUsage.inputTokens, other.cacheUsage.inputTokens) else { return nil }
        return Self(tokens: tokens, unknownTokens: missingTokens, costMicros: cost, unknownCost: missingCost,
                    cacheUsage: PromptCacheUsage(readTokens: read, inputTokens: prompt))
    }
}

struct NodeUsageAmount: Decodable, Equatable {
    let usage: DailyUsage
    let hasCredits: Bool

    private enum CodingKeys: String, CodingKey { case hasCredits }

    init(from decoder: Decoder) throws {
        usage = try DailyUsage(from: decoder)
        hasCredits = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Bool.self, forKey: .hasCredits) ?? false
    }
}

struct NodeDeviceSummary: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let local: Bool
    let active: Bool
    let partialSources: Int
    let observed: Date
    let usage: DailyUsage

    private enum CodingKeys: String, CodingKey { case id, name, local, active, partialSources, observed }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        name = try fields.decode(String.self, forKey: .name)
        local = try fields.decode(Bool.self, forKey: .local)
        active = try fields.decode(Bool.self, forKey: .active)
        let epoch = try fields.decode(Int64.self, forKey: .observed)
        guard (0...253_402_300_799).contains(epoch) else {
            throw DecodingError.dataCorruptedError(forKey: .observed, in: fields, debugDescription: "Invalid observation date")
        }
        observed = Date(timeIntervalSince1970: Double(epoch))
        partialSources = try fields.decodeIfPresent(Int.self, forKey: .partialSources) ?? 0
        guard partialSources >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .partialSources, in: fields, debugDescription: "Invalid source count")
        }
        usage = try DailyUsage(from: decoder)
    }
}

struct NodeAgentSummary: Decodable, Equatable {
    let id: String
    let localOnly: Bool
    let creditsPicos: Int64?
    let usage: DailyUsage

    private enum CodingKeys: String, CodingKey { case id, localOnly, creditsPicos }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        localOnly = try fields.decode(Bool.self, forKey: .localOnly)
        creditsPicos = try fields.decodeIfPresent(String.self, forKey: .creditsPicos).map {
            guard let value = Int64($0), value >= 0 else {
                throw DecodingError.dataCorruptedError(forKey: .creditsPicos, in: fields, debugDescription: "Invalid credit count")
            }
            return value
        }
        usage = try DailyUsage(from: decoder)
    }
}

struct DailyAgentRow: Identifiable, Equatable {
    let id: String
    let usage: DailyUsage
    let sessions: Int?
    let creditsPicos: Int64?

    static func rows(node: NodeDailySummary?, local: [MenuBarTodaySummary.ProviderToday]) -> [Self] {
        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.providerId, $0) })
        var rows: [String: Self] = [:]
        for agent in node?.agents ?? [] {
            let detail = agent.localOnly ? localByID[agent.id] : nil
            let credits = agent.creditsPicos ?? detail.flatMap { $0.creditEvents > 0 ? $0.creditsPicos : nil }
            rows[agent.id] = Self(id: agent.id, usage: agent.usage, sessions: detail?.knownSessionCount, creditsPicos: credits)
        }

        // A new node may receive a remote replica before it finishes its first local scan.
        if node?.devices.contains(where: \.local) != true {
            for row in local {
                let remote = rows[row.providerId]
                let localUsage = DailyUsage(local: row)
                let credit = row.creditEvents > 0 ? row.creditsPicos : nil
                if let remote {
                    guard let usage = remote.usage.adding(localUsage),
                          let credits = sumCounts(remote.creditsPicos ?? 0, credit ?? 0) else {
                        rows.removeValue(forKey: row.providerId)
                        continue
                    }
                    rows[row.providerId] = Self(id: row.providerId, usage: usage, sessions: nil,
                                                creditsPicos: credit == nil && remote.creditsPicos == nil ? nil : credits)
                } else {
                    rows[row.providerId] = Self(id: row.providerId, usage: localUsage, sessions: row.knownSessionCount, creditsPicos: credit)
                }
            }
        }
        return rows.values.sorted {
            if $0.usage.tokens != $1.usage.tokens { return $0.usage.tokens > $1.usage.tokens }
            return $0.id < $1.id
        }
    }
}

struct NodeDailySummary: Decodable, Equatable {
    let day: String
    let devices: [NodeDeviceSummary]
    let agents: [NodeAgentSummary]
    let models: [DailyModelSummary.Row]?
    let history: NodeUsageHistory?

    var includesLocal: Bool { devices.contains(where: \.local) }
    var includesRemote: Bool { devices.contains { !$0.local } }

    var visibleMachines: [NodeDeviceSummary] {
        let active = devices.filter(\.active)
        guard active.count > 1 else { return [] }
        return active.sorted { lhs, rhs in
            if lhs.local != rhs.local { return lhs.local }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

struct DailyModelSummary: Equatable {
    struct Row: Identifiable, Equatable, Decodable {
        let id: String
        let usage: DailyUsage
        let hasCredits: Bool

        init(id: String, usage: DailyUsage, hasCredits: Bool = false) {
            self.id = id
            self.usage = usage
            self.hasCredits = hasCredits
        }

        private enum CodingKeys: String, CodingKey { case model }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = ModelNameNormalizer.canonical(try fields.decode(String.self, forKey: .model))
            let amount = try NodeUsageAmount(from: decoder)
            usage = amount.usage
            hasCredits = amount.hasCredits
        }
    }

    let rows: [Row]
    let total: DailyUsage

    static func from(node: NodeDailySummary?, local: [MenuBarTodaySummary.ModelToday]) -> Self? {
        let cached = node?.models
        // 旧快照有远端用量时，等设备服务发布模型明细后再显示合计。
        if cached == nil, node?.devices.contains(where: { !$0.local && $0.active }) == true {
            return nil
        }

        var models = cached ?? []
        if cached == nil || node?.devices.contains(where: \.local) != true {
            models += local.map { row in
                Row(id: row.model, usage: DailyUsage(
                    tokens: row.tokens,
                    unknownTokens: Int64(row.tokenUnreportedEvents),
                    costMicros: row.costUsdMicros,
                    unknownCost: Int64(row.unknownCostEvents),
                    cacheUsage: row.cacheUsage
                ), hasCredits: row.hasCredits)
            }
        }

        return merging(models)
    }

    static func merging(_ models: [Row]) -> Self? {
        var byID: [String: Row] = [:]
        var total = DailyUsage.zero
        for row in models where row.usage.hasUsage(hasCredits: row.hasCredits) {
            let previous = byID[row.id]
            guard let usage = (previous?.usage ?? .zero).adding(row.usage),
                  let combined = total.adding(row.usage) else { return nil }
            byID[row.id] = Row(id: row.id, usage: usage, hasCredits: previous?.hasCredits == true || row.hasCredits)
            total = combined
        }
        let rows = byID.values.sorted {
            if $0.usage.tokens != $1.usage.tokens { return $0.usage.tokens > $1.usage.tokens }
            return $0.id < $1.id
        }
        return Self(rows: rows, total: total)
    }
}

enum DesktopNode {
    static var directory: URL { TokenMeterPaths.baseDirectory().appendingPathComponent("node", isDirectory: true) }
    static func summaryURL(in directory: URL) -> URL { directory.appendingPathComponent("summary.json") }

    struct IndexStatus: Decodable {
        let at: Int64
        let scanned: Int
        let failures: Int
        let interval: Int
    }

    static func dailySummary(now: Date = Date(), directory: URL = Self.directory) -> NodeDailySummary? {
        let date = ISO8601DateFormatter()
        date.formatOptions = [.withFullDate]
        date.timeZone = .current
        guard let data = try? Data(contentsOf: summaryURL(in: directory)),
              let report = try? JSONDecoder().decode(NodeDailySummary.self, from: data),
              report.day == date.string(from: now) else { return nil }
        return report
    }

    static func indexStatus() -> IndexStatus? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("native-index.json")),
              let status = try? JSONDecoder().decode(IndexStatus.self, from: data),
              Date().timeIntervalSince1970 - Double(status.at) < Double(max(120, status.interval * 2 + 60)) else { return nil }
        return status
    }

    static func setPaused(_ paused: Bool) {
        let url = directory.appendingPathComponent("index-paused")
        if paused { try? Data().write(to: url, options: .atomic) } else { try? FileManager.default.removeItem(at: url) }
    }

    static func installIfNeeded() {
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/token-meter")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { return }
        let task = Process()
        task.executableURL = cli
        task.arguments = ["--state", directory.path, "service", "ensure"]
        var environment = ProcessInfo.processInfo.environment
        environment["TOKEN_METER_APP_BUILD"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        task.environment = environment
        try? task.run()
    }
}
