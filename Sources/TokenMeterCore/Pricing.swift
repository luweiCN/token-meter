import Foundation

public struct ModelPricing: Equatable, Codable {
    public let inputPerMTok: Double
    public let outputPerMTok: Double
    public let cacheReadPerMTok: Double
    public let cacheWrite5mPerMTok: Double
    public let cacheWrite1hPerMTok: Double

    public init(
        inputPerMTok: Double,
        outputPerMTok: Double,
        cacheReadPerMTok: Double,
        cacheWrite5mPerMTok: Double,
        cacheWrite1hPerMTok: Double
    ) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.cacheWrite5mPerMTok = cacheWrite5mPerMTok
        self.cacheWrite1hPerMTok = cacheWrite1hPerMTok
    }
}

public struct PricingSnapshot: Equatable, Codable {
    public let snapshotVersion: String
    public let source: String
    public let models: [String: ModelPricing]

    public init(snapshotVersion: String, source: String, models: [String: ModelPricing]) {
        self.snapshotVersion = snapshotVersion
        self.source = source
        self.models = models
    }

    /// 从随包分发的快照加载。运行时不发起任何网络请求。
    public static func loadBundled() throws -> PricingSnapshot {
        guard let url = Bundle.module.url(forResource: "litellm-pricing", withExtension: "json") else {
            throw PricingError.bundledSnapshotMissing
        }
        return try JSONDecoder().decode(PricingSnapshot.self, from: Data(contentsOf: url))
    }
}

public enum PricingError: Error, Equatable {
    case bundledSnapshotMissing
}
