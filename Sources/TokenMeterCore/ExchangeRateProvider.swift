import Foundation

/// 当前 USD→CNY 显示汇率及其抓取时刻。只服务于显示层换算：
/// 计价与存储永远以美元微元为准，这个值旧一点不影响任何账目。
public struct ExchangeRate: Equatable, Codable {
    public let usdToCny: Double
    public let fetchedAt: Date

    public init(usdToCny: Double, fetchedAt: Date) {
        self.usdToCny = usdToCny
        self.fetchedAt = fetchedAt
    }
}

/// 日更汇率源（open.er-api.com 免费公开端点，无需 key，约每日 00:30 UTC 更新）。
/// 读取策略：磁盘缓存 < 24h 直接用；过期先拉新，拉不到退回缓存；
/// 缓存也没有时用打包兜底常数。全部失败也不会影响菜单栏/弹窗主体显示。
public enum ExchangeRateProvider {
    public static let endpoint = URL(string: "https://open.er-api.com/v6/latest/USD")!
    /// 兜底值（2026-08 查证 6.7569 附近）；只在外网与缓存都不可用时生效。
    public static let fallbackRate = 6.76
    /// 缓存新鲜窗口：24 小时。日更源配一天足够。
    public static let refreshInterval: TimeInterval = 24 * 3600

    public static func cacheURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        TokenMeterPaths.baseDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("exchange-rate.json")
    }

    /// 同步读缓存；没有/损坏返回 nil。启动首帧用，不等网络。
    public static func loadCache(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ExchangeRate? {
        guard let data = try? Data(contentsOf: cacheURL(homeDirectory: homeDirectory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ExchangeRate.self, from: data)
    }

    /// 同步兜底：缓存优先，否则常数。
    public static func cachedOrFallback(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ExchangeRate {
        loadCache(homeDirectory: homeDirectory)
            ?? ExchangeRate(usdToCny: fallbackRate, fetchedAt: .distantPast)
    }

    /// 缓存过期才联网刷新；失败退回旧缓存/常数。返回值一定是可用的显示汇率。
    public static func refreshIfNeeded(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) async -> ExchangeRate {
        let cached = loadCache(homeDirectory: homeDirectory)
        if let cached, now.timeIntervalSince(cached.fetchedAt) < refreshInterval {
            return cached
        }
        if let fresh = await fetch() {
            save(fresh, homeDirectory: homeDirectory)
            return fresh
        }
        return cached ?? ExchangeRate(usdToCny: fallbackRate, fetchedAt: .distantPast)
    }

    public static func fetch() async -> ExchangeRate? {
        guard let (data, response) = try? await URLSession.shared.data(from: endpoint),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = json["rates"] as? [String: Double],
              let cny = rates["CNY"],
              cny > 0 else {
            return nil
        }
        return ExchangeRate(usdToCny: cny, fetchedAt: Date())
    }

    private static func save(
        _ rate: ExchangeRate,
        homeDirectory: URL
    ) {
        let url = cacheURL(homeDirectory: homeDirectory)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(rate) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
