import Foundation

/// custom-pricing.json 的单个条目。所有字段都可省略：
/// - 省略的价格字段逐项沿用内置快照价（含 tiered）——只想开 ignoreReported 时
///   一个价格都不用抄；内置快照里也没有的模型则必须写全五价。
/// - `ignoreReported: true` = 忽略日志上报成本（OpenCode/OMP 会带），强制按本地价计。
public struct CustomPricingEntry: Equatable, Codable {
    public let inputPerMTok: Double?
    public let outputPerMTok: Double?
    public let cacheReadPerMTok: Double?
    public let cacheWrite5mPerMTok: Double?
    public let cacheWrite1hPerMTok: Double?
    public let tiered: PeakOffPeakPricing?
    public let ignoreReported: Bool?

    public init(
        inputPerMTok: Double? = nil,
        outputPerMTok: Double? = nil,
        cacheReadPerMTok: Double? = nil,
        cacheWrite5mPerMTok: Double? = nil,
        cacheWrite1hPerMTok: Double? = nil,
        tiered: PeakOffPeakPricing? = nil,
        ignoreReported: Bool? = nil
    ) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.cacheWrite5mPerMTok = cacheWrite5mPerMTok
        self.cacheWrite1hPerMTok = cacheWrite1hPerMTok
        self.tiered = tiered
        self.ignoreReported = ignoreReported
    }
}

/// 用户自定义模型定价：`~/.token-meter/custom-pricing.json`（手写、无 UI）。
///
/// 条目价格覆盖随包快照（同名覆盖、新键补充）；全 0 单价即免费模型——成本按 $0
/// 计为 computed，不再显示「价格未知」。`ignoreReported: true` 用于上报价口径不对的
/// 场景（例如 OpenCode 固定按空闲档给 DeepSeek 计价、不随高峰翻倍）：该模型忽略
/// 上报成本、强制本地峰谷计价。上报原值由 usage_events.reported_cost_usd_micros
/// 留底，移除开关后自动还原。
///
/// 键会先过 `ModelNameNormalizer.canonical`（与 usage_events.model_canonical 同一
/// 归一化），所以写 "omniroute/cx/gpt-5.5" 与写 "gpt-5.5" 等效。
///
/// 文件缺失 = 无覆盖（正常状态）。存在但读不了 / 解析失败 = 按「无有效覆盖」处理且
/// fingerprint 置 nil，每轮扫描都会重试——用户修好 JSON 后立即生效，无需重启。
public struct CustomPricingOverrides: Equatable {
    public let models: [String: CustomPricingEntry]
    /// 变化检测指纹（"<size>:<mtime_ms>"）。文件不存在或无效时为 nil。
    public let fingerprint: String?
    /// 覆盖键经 ModelNameNormalizer 归一后的集合，圈定存量事件重投影的范围。
    public let canonicalKeys: Set<String>
    /// 开了 "ignoreReported": true 的键（canonical）。这些模型连上报成本也强制本地计价。
    public let ignoredReportedKeys: Set<String>

    public static let empty = CustomPricingOverrides(
        models: [:], fingerprint: nil, canonicalKeys: [], ignoredReportedKeys: []
    )

    public init(
        models: [String: CustomPricingEntry],
        fingerprint: String?,
        canonicalKeys: Set<String>,
        ignoredReportedKeys: Set<String> = []
    ) {
        self.models = models
        self.fingerprint = fingerprint
        self.canonicalKeys = canonicalKeys
        self.ignoredReportedKeys = ignoredReportedKeys
    }

    public static func load(url: URL) throws -> CustomPricingOverrides {
        let metadata = try FileManager.default.attributesOfItem(atPath: url.path)
        let sizeBytes = (metadata[.size] as? NSNumber)?.int64Value ?? 0
        let modifiedAt = (metadata[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: CustomPricingEntry].self, from: data) else {
            return .empty
        }

        var canonicalKeys = Set<String>()
        var ignoredReportedKeys = Set<String>()
        for (key, entry) in decoded {
            let normalized = ModelNameNormalizer.canonical(key)
            guard normalized != ModelNameNormalizer.unknown else { continue }
            canonicalKeys.insert(normalized)
            if entry.ignoreReported == true {
                ignoredReportedKeys.insert(normalized)
            }
        }
        return CustomPricingOverrides(
            models: decoded,
            fingerprint: "\(sizeBytes):\(Int64((modifiedAt * 1000).rounded()))",
            canonicalKeys: canonicalKeys,
            ignoredReportedKeys: ignoredReportedKeys
        )
    }

    /// 把条目与内置快照逐字段合并成完整价：条目缺的字段从内置价继承（键先用原名查、
    /// 再用 canonical 查）。任何一项价格在两边都取不到 → 无法安全计价，整个条目的
    /// 价格部分（连同 ignoreReported）一起放弃，绝不用半份价格算账。
    public func resolvedModels(bundled: PricingSnapshot) -> (models: [String: ModelPricing], droppedKeys: Set<String>) {
        var resolved: [String: ModelPricing] = [:]
        var dropped = Set<String>()
        for (key, entry) in models {
            let normalized = ModelNameNormalizer.canonical(key)
            let base = bundled.models[key] ?? bundled.models[normalized]
            func inherit(_ value: Double?, _ fallback: Double?) -> Double? {
                value ?? fallback
            }
            guard let input = inherit(entry.inputPerMTok, base?.inputPerMTok),
                  let output = inherit(entry.outputPerMTok, base?.outputPerMTok),
                  let cacheRead = inherit(entry.cacheReadPerMTok, base?.cacheReadPerMTok),
                  let cacheWrite5m = inherit(entry.cacheWrite5mPerMTok, base?.cacheWrite5mPerMTok),
                  let cacheWrite1h = inherit(entry.cacheWrite1hPerMTok, base?.cacheWrite1hPerMTok) else {
                dropped.insert(normalized)
                continue
            }
            resolved[key] = ModelPricing(
                inputPerMTok: input,
                outputPerMTok: output,
                cacheReadPerMTok: cacheRead,
                cacheWrite5mPerMTok: cacheWrite5m,
                cacheWrite1hPerMTok: cacheWrite1h,
                tiered: entry.tiered ?? base?.tiered,
                ignoreReported: entry.ignoreReported
            )
        }
        return (resolved, dropped)
    }
}
