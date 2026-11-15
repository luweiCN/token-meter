import Foundation

/// custom-pricing.json 的单个条目。所有字段都可省略：
/// - 省略的价格字段逐项沿用当前生效快照价（含 longContext/tiered）——只想开
///   ignoreReported 时一个价格都不用抄；新模型必须提供输入/输出价，缓存缺价保持未知。
/// - `ignoreReported: true` = 忽略日志上报成本（OpenCode/OMP 会带），强制按本地价计。
public struct CustomPricingEntry: Equatable, Codable {
    public let inputPerMTok: Double?
    public let outputPerMTok: Double?
    public let cacheReadPerMTok: Double?
    public let cacheWrite5mPerMTok: Double?
    public let cacheWrite1hPerMTok: Double?
    public let longContext: [LongContextPricing]?
    public let tiered: PeakOffPeakPricing?
    public let ignoreReported: Bool?

    public init(
        inputPerMTok: Double? = nil,
        outputPerMTok: Double? = nil,
        cacheReadPerMTok: Double? = nil,
        cacheWrite5mPerMTok: Double? = nil,
        cacheWrite1hPerMTok: Double? = nil,
        longContext: [LongContextPricing]? = nil,
        tiered: PeakOffPeakPricing? = nil,
        ignoreReported: Bool? = nil
    ) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.cacheWrite5mPerMTok = cacheWrite5mPerMTok
        self.cacheWrite1hPerMTok = cacheWrite1hPerMTok
        self.longContext = longContext
        self.tiered = tiered
        self.ignoreReported = ignoreReported
    }

    private enum CodingKeys: String, CodingKey {
        case inputPerMTok, outputPerMTok, cacheReadPerMTok, cacheWrite5mPerMTok, cacheWrite1hPerMTok
        case longContext, tiered, ignoreReported
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            inputPerMTok: try values.decodeIfPresent(Double.self, forKey: .inputPerMTok),
            outputPerMTok: try values.decodeIfPresent(Double.self, forKey: .outputPerMTok),
            cacheReadPerMTok: try values.decodeIfPresent(Double.self, forKey: .cacheReadPerMTok),
            cacheWrite5mPerMTok: try values.decodeIfPresent(Double.self, forKey: .cacheWrite5mPerMTok),
            cacheWrite1hPerMTok: try values.decodeIfPresent(Double.self, forKey: .cacheWrite1hPerMTok),
            longContext: try values.decodeContextTiersIfPresent(forKey: .longContext),
            tiered: try values.decodeIfPresent(PeakOffPeakPricing.self, forKey: .tiered),
            ignoreReported: try values.decodeIfPresent(Bool.self, forKey: .ignoreReported)
        )
    }
}

/// 用户自定义模型定价：`~/.token-meter/custom-pricing.json`（手写、无 UI）。
///
/// 条目价格覆盖当前生效快照（同名覆盖、新键补充）；全 0 单价即免费模型——成本按 $0
/// 计为 computed，不再显示「价格未知」。带峰谷价的模型无论是否有供应商上报价，
/// 都按本地时刻表计价；`ignoreReported: true` 仍可用于没有峰谷价、但上报价口径不对
/// 的固定价模型。上报原值由 usage_events.reported_cost_usd_micros 留底。
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

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let decoded = try? decoder.decode([String: CustomPricingEntry].self, from: data) else {
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

    /// 把条目与生效快照逐字段合并成完整价：条目缺的字段从快照继承（键先用原名查、
    /// 再用 canonical 查）。缺少输入/输出价或规则非法则整个条目（含 ignoreReported）
    /// 放弃；缓存缺价由计价器按请求实际消费判断。longContext: [] 显式关闭上下文分档。
    public func resolvedModels(bundled: PricingSnapshot) -> (models: [String: ModelPricing], droppedKeys: Set<String>) {
        var resolved: [String: ModelPricing] = [:]
        var dropped = Set<String>()
        let bundledByCanonical = CostCalculator.canonicalModels(from: bundled)
        for key in models.keys.sorted() {
            guard let entry = models[key] else { continue }
            let normalized = ModelNameNormalizer.canonical(key)
            let base = bundled.models[key] ?? bundled.models[normalized] ?? bundledByCanonical[normalized]
            func inherit(_ value: Double?, _ fallback: Double?) -> Double? {
                value ?? fallback
            }
            guard let input = inherit(entry.inputPerMTok, base?.inputPerMTok),
                  let output = inherit(entry.outputPerMTok, base?.outputPerMTok) else {
                if resolved[normalized] == nil {
                    dropped.insert(normalized)
                }
                continue
            }
            // 覆盖直接以 canonical 键合并，保证 omniroute/cx/... 这类写法
            // 不会在 CostCalculator 的字典序撞名裁决中输给随包裸键。
            guard resolved[normalized] == nil else { continue }
            let pricing = ModelPricing(
                inputPerMTok: input,
                outputPerMTok: output,
                cacheReadPerMTok: inherit(entry.cacheReadPerMTok, base?.cacheReadPerMTok),
                cacheWrite5mPerMTok: inherit(entry.cacheWrite5mPerMTok, base?.cacheWrite5mPerMTok),
                cacheWrite1hPerMTok: inherit(entry.cacheWrite1hPerMTok, base?.cacheWrite1hPerMTok),
                longContext: entry.longContext ?? base?.longContext ?? [],
                tiered: entry.tiered ?? base?.tiered,
                ignoreReported: entry.ignoreReported
            )
            guard (try? pricing.validate(allowFree: true)) != nil else {
                dropped.insert(normalized)
                continue
            }
            resolved[normalized] = pricing
            dropped.remove(normalized)
        }
        return (resolved, dropped)
    }
}
