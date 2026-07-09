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
        // LiteLLM 的 key 是原始名。归一化后会撞名：claude-3-opus 与
        // claude-3-opus-20240229 都归到 claude-3-opus。按字典序取第一个——
        // 裸名总排在带日期后缀的前面，且同一份快照总是得到同一结果。
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
