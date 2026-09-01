import Foundation

public enum CostSource: String, Equatable {
    case reported
    case computed
    case unknown
}

public struct CostCalculator {
    private let canonicalIndex: [String: ModelPricing]
    /// 没有模型级 tiered 定价、但需要忽略日志上报成本的模型
    ///（custom-pricing 的 ignoreReported）。tiered 模型由自身定价配置自动强制本地计价。
    private let ignoreReportedModels: Set<String>

    /// 定价键侧的前缀白名单（与 scripts/transform_pricing.py 的 PROVIDER_PREFIXES
    /// 逐项一致，scripts/test_transform_pricing.py 对账）。定价键只剥白名单前缀：
    /// 第三方托管键（azure_ai/、fireworks_ai/、cloudflare/ 等）保留斜杠、不撞官方名，
    /// 防托管价冒充官方价——azure_ai/deepseek-v4-pro 的 $1.74 曾把官方 $0.435 覆盖掉，
    /// 整月用量被按 4 倍计费。用量侧（事件模型名）仍走 ModelNameNormalizer 的通用规则。
    static let pricingKeyPrefixes = [
        "vertex_ai/", "bedrock/", "anthropic/", "openai/", "openai-codex/", "zai/",
        "deepseek/", "gemini/", "meta/",
        "omniroute/", "9router/", "cx/", "opencode-go/", "ocg/",
        "glm-cn/", "glm/", "antigravity/", "google-antigravity/", "zhipu-coding-plan/",
    ]

    /// 定价键归一：循环剥白名单前缀，再剥八位日期后缀与网关档位后缀。
    /// 规则与 transform_pricing.canonical 同源，必须逐字符一致。
    static func pricingKeyCanonical(_ key: String) -> String {
        var name = key.lowercased()
        var stripped = true
        while stripped {
            stripped = false
            for prefix in pricingKeyPrefixes {
                if name.hasPrefix(prefix) {
                    name.removeFirst(prefix.count)
                    stripped = true
                    break
                }
            }
        }
        if let range = name.range(of: "-[0-9]{8}$", options: .regularExpression) {
            name.removeSubrange(range)
        }
        for suffix in ["-xhigh", "-high"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        return name.isEmpty ? "unknown" : name
    }

    public init(snapshot: PricingSnapshot, ignoreReportedModels: Set<String> = []) {
        var index: [String: ModelPricing] = [:]
        // LiteLLM 的 key 是原始名，归一化后会撞名：一个规范名常对应多个原始 key。
        // 实测快照有 54 组，主因是 provider 前缀（claude-opus-4-8 与
        // vertex_ai/claude-opus-4-8），其次才是日期后缀。取字典序最小的那个。
        //
        // sorted 不可省略：Swift 字典的迭代顺序取决于每进程随机的哈希种子，
        // 同一份字典连跑十次会得到四种顺序。去掉它，first-write-wins 就成了掷骰子。
        for (key, pricing) in snapshot.models.sorted(by: { $0.key < $1.key }) {
            let canonical = CostCalculator.pricingKeyCanonical(key)
            if index[canonical] == nil {
                index[canonical] = pricing
            }
        }
        canonicalIndex = index
        self.ignoreReportedModels = ignoreReportedModels
    }

    public func cost(for event: UsageEvent) -> (micros: Int64?, source: CostSource) {
        let canonicalModel = ModelNameNormalizer.canonical(event.modelName)
        let pricing = canonicalIndex[canonicalModel]

        // 峰谷价属于模型而不是供应商。只要本地定价表把模型标成 tiered，
        // 就必须按事件时间选本地档位；不能先采信供应商上报的固定金额，
        // 否则 OpenCode Go、Command Code、直连 API 等来源会得到不同口径。
        // 未标成 tiered 的模型仍保持原语义：有上报价时优先采信上报价。
        if pricing?.tiered == nil,
           let reported = event.reportedCostUSDMicros,
           !ignoreReportedModels.contains(canonicalModel) {
            return (reported, .reported)
        }

        // 不做家族兜底。同家族价格能差 100 倍（gpt-5 $0.05 vs gpt-5.5 $5.00），
        // 借来的价格会被标成 computed，用户无从分辨那是不是真的。
        // 匹配不到就诚实地说不知道，让人去跑 scripts/update-pricing.sh。
        guard let pricing else {
            return (nil, .unknown)
        }

        // 峰谷价（如 DeepSeek）：生效时刻之后按事件发生时刻选高峰/空闲价；
        // 生效时刻之前的存量事件仍按基础价计，重扫历史数据时不会把旧账算成新价。
        let rate: RateCard
        if let tiered = pricing.tiered {
            switch tiered.phase(at: event.observedAt) {
            case .peak: rate = tiered.peak
            case .offPeak: rate = tiered.offPeak
            case .notYetEffective: rate = pricing.rate
            }
        } else {
            rate = pricing.rate
        }

        let usd =
            perMillion(event.inputTokens, rate.inputPerMTok) +
            perMillion(event.outputTokens, rate.outputPerMTok) +
            perMillion(event.cacheReadTokens, rate.cacheReadPerMTok) +
            perMillion(event.cacheWrite5mTokens, rate.cacheWrite5mPerMTok) +
            perMillion(event.cacheWrite1hTokens, rate.cacheWrite1hPerMTok)

        return (Int64((usd * 1_000_000).rounded()), .computed)
    }

    private func perMillion(_ tokens: Int64, _ pricePerMTok: Double) -> Double {
        Double(tokens) / 1_000_000.0 * pricePerMTok
    }
}
