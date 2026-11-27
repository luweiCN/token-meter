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
    /// `xai/` 是 LiteLLM 里 Grok 的官方前缀；`vertex_ai/` 写在前面，所以
    /// `vertex_ai/xai/...` 会先剥宿主再剥 `xai/`。
    static let pricingKeyPrefixes = [
        "vertex_ai/", "bedrock/", "anthropic/", "openai/", "openai-codex/", "zai/",
        "deepseek/", "gemini/", "meta/", "xai/",
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

    /// 计价查找顺序。第一个键是用量侧 canonical，后面才是别名。
    ///
    /// Grok Build 把同一个模型写成末尾 `-build`（`grok-4.7-build`）。没有专属价时用基础模型，
    /// 不再为每个版本登记一对相同的键。只剥这一个后缀：`grok-4.7-build-fast` 以 `-fast` 结尾，
    /// 是另一档单价。`grok-build` 本身是产品名，不是「grok + Build」。
    /// 不写进 `ModelNameNormalizer`：展示名和 `model_canonical` 仍分开。
    static func pricingCandidates(for canonicalModel: String) -> [String] {
        let suffix = "-build"
        guard canonicalModel.hasPrefix("grok-"), canonicalModel.hasSuffix(suffix) else {
            return [canonicalModel]
        }
        let base = String(canonicalModel.dropLast(suffix.count))
        guard !base.isEmpty, base != "grok" else { return [canonicalModel] }
        return [canonicalModel, base]
    }

    /// 价格指纹变了的计价键，要重算哪些用量键。`grok-4.7-build` 不在索引里，
    /// 但它的价来自 `grok-4.7`，基础价变化时这两行都要重投影。
    static func usageKeysAffected(by changedPricingKeys: Set<String>, usedKeys: Set<String>) -> Set<String> {
        Set(usedKeys.filter { key in
            pricingCandidates(for: key).contains(where: changedPricingKeys.contains)
        })
    }

    public init(snapshot: PricingSnapshot, ignoreReportedModels: Set<String> = []) {
        self.init(canonicalModels: Self.canonicalModels(from: snapshot), ignoreReportedModels: ignoreReportedModels)
    }

    init(canonicalModels: [String: ModelPricing], ignoreReportedModels: Set<String> = []) {
        canonicalIndex = canonicalModels.filter {
            (try? $0.value.validate(allowFree: true)) != nil
        }
        self.ignoreReportedModels = ignoreReportedModels
    }

    /// 快照原始键 → 用量侧 canonical 键。扫描器的价格变更对账与计价必须共用
    /// 这一份撞名规则，否则会出现“对账说价格已生效，计价却命中另一个键”。
    static func canonicalModels(from snapshot: PricingSnapshot) -> [String: ModelPricing] {
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
        return index
    }

    public func cost(for event: UsageEvent) -> (micros: Int64?, source: CostSource) {
        let canonicalModel = ModelNameNormalizer.canonical(event.modelName)
        let pricing = Self.pricingCandidates(for: canonicalModel).lazy.compactMap { canonicalIndex[$0] }.first

        // 峰谷价属于模型而不是供应商。只要本地定价表把模型标成 tiered，
        // 就必须按事件时间选本地档位；不能先采信供应商上报的固定金额，
        // 否则 OpenCode Go、Command Code、直连 API 等来源会得到不同口径。
        // 未标成 tiered 的模型仍保持原语义：有上报价时优先采信上报价。
        if pricing?.tiered == nil,
           let reported = event.reportedCostUSDMicros,
           !ignoreReportedModels.contains(canonicalModel) {
            return (reported, .reported)
        }

        // 来源未上报 Token 时，0 只是数据库占位，不是一次真实的零 Token 请求。
        // 即使模型能命中价格表也不能据此算出 $0。
        guard event.tokensReported else {
            return (nil, .unknown)
        }

        // Credits 是供应商资源单位，不能换算成 USD。若请求确实消耗了 Credits，
        // 但来源的全部 Token 字段为 0，则用模型单价乘出 $0 会制造“免费”的假象。
        if event.totalTokens == 0,
           let credit = event.creditUsage,
           credit.actualPicos > 0 || (credit.originalPicos ?? 0) > 0 {
            return (nil, .unknown)
        }

        // 不做家族兜底。同家族价格能差 100 倍（gpt-5 $0.05 vs gpt-5.5 $5.00），
        // 借来的价格会被标成 computed，用户无从分辨那是不是真的。
        // 匹配不到就诚实地说不知道，等待经过校验的新快照或用户覆盖补齐。
        guard let pricing else {
            return (nil, .unknown)
        }

        // 峰谷价（如 DeepSeek）：生效时刻之后按事件发生时刻选高峰/空闲价；
        // 生效时刻之前的存量事件仍按基础价计。长上下文价按单次完整输入
        // （未缓存 + 缓存读 + 缓存写）切档；整次请求使用最高已超过阈值的费率。
        let rate: RateCard
        if let tiered = pricing.tiered {
            switch tiered.phase(at: event.observedAt) {
            case .peak: rate = tiered.peak
            case .offPeak: rate = tiered.offPeak
            case .notYetEffective: rate = pricing.rate
            }
        } else {
            let input = billableInputTokens(for: event)
            rate = pricing.longContext.last(where: { input > $0.thresholdTokens })?.rate ?? pricing.rate
        }

        let components: [(Int64, Double?)] = [
            (event.inputTokens, rate.inputPerMTok), (event.outputTokens, rate.outputPerMTok),
            (event.cacheReadTokens, rate.cacheReadPerMTok),
            (event.cacheWrite5mTokens, rate.cacheWrite5mPerMTok),
            (event.cacheWrite1hTokens, rate.cacheWrite1hPerMTok),
        ]
        var micros: Double = 0
        for (tokens, price) in components {
            guard tokens >= 0 else { return (nil, .unknown) }
            guard tokens > 0 else { continue }
            guard let price else { return (nil, .unknown) }
            // USD/百万 Token × Token = 微美元，最后统一舍入。
            micros += Double(tokens) * price
        }
        let rounded = micros.rounded()
        guard rounded.isFinite, rounded < Double(Int64.max) else { return (nil, .unknown) }
        return (Int64(rounded), .computed)
    }

    private func billableInputTokens(for event: UsageEvent) -> Int64 {
        [event.inputTokens, event.cacheReadTokens, event.cacheWrite5mTokens, event.cacheWrite1hTokens]
            .reduce(0) { total, value in
                let (sum, overflow) = total.addingReportingOverflow(value)
                return overflow ? .max : sum
            }
    }
}
