import Foundation

public enum CostSource: String, Equatable {
    case reported
    case computed
    case unknown
}

public struct CostCalculator {
    private let canonicalIndex: [String: ModelPricing]

    public init(snapshot: PricingSnapshot) {
        var index: [String: ModelPricing] = [:]
        // LiteLLM 的 key 是原始名，归一化后会撞名：一个规范名常对应多个原始 key。
        // 实测快照有 54 组，主因是 provider 前缀（claude-opus-4-8 与
        // vertex_ai/claude-opus-4-8），其次才是日期后缀。取字典序最小的那个。
        //
        // sorted 不可省略：Swift 字典的迭代顺序取决于每进程随机的哈希种子，
        // 同一份字典连跑十次会得到四种顺序。去掉它，first-write-wins 就成了掷骰子。
        for (key, pricing) in snapshot.models.sorted(by: { $0.key < $1.key }) {
            let canonical = ModelNameNormalizer.canonical(key)
            if index[canonical] == nil {
                index[canonical] = pricing
            }
        }
        canonicalIndex = index
    }

    public func cost(for event: UsageEvent) -> (micros: Int64?, source: CostSource) {
        if let reported = event.reportedCostUSDMicros {
            return (reported, .reported)
        }

        // 不做家族兜底。同家族价格能差 100 倍（gpt-5 $0.05 vs gpt-5.5 $5.00），
        // 借来的价格会被标成 computed，用户无从分辨那是不是真的。
        // 匹配不到就诚实地说不知道，让人去跑 scripts/update-pricing.sh。
        guard let pricing = canonicalIndex[ModelNameNormalizer.canonical(event.modelName)] else {
            return (nil, .unknown)
        }

        let usd =
            perMillion(event.inputTokens, pricing.inputPerMTok) +
            perMillion(event.outputTokens, pricing.outputPerMTok) +
            perMillion(event.cacheReadTokens, pricing.cacheReadPerMTok) +
            perMillion(event.cacheWrite5mTokens, pricing.cacheWrite5mPerMTok) +
            perMillion(event.cacheWrite1hTokens, pricing.cacheWrite1hPerMTok)

        return (Int64((usd * 1_000_000).rounded()), .computed)
    }

    private func perMillion(_ tokens: Int64, _ pricePerMTok: Double) -> Double {
        Double(tokens) / 1_000_000.0 * pricePerMTok
    }
}
