import Foundation
import TokenMeterCore

struct PopoverTokenAmount {
    let tokens: Int64
    var unreportedEvents: Int64 = 0

    private var isUnreported: Bool { unreportedEvents > 0 && tokens == 0 }

    var aggregateText: String { isUnreported ? "—" : UsageFormatter.compactTokensAggregated(tokens) }
    var dailyText: String { isUnreported ? "—" : UsageFormatter.compactTokens(tokens) }

    var detail: String {
        isUnreported ? "—" : "\(tokens.formatted(.number.locale(Locale(identifier: "zh_CN")))) Token"
    }
}

extension PromptCacheUsage {
    var percentText: String {
        guard let hitRate else { return "暂无数据" }
        return hitRate.formatted(.percent.locale(Locale(identifier: "zh_CN")).precision(.fractionLength(1)))
    }

    var detail: String {
        guard inputTokens > 0 else { return "暂无已上报的输入 Token，无法计算缓存命中率" }
        let format = IntegerFormatStyle<Int64>.number.locale(Locale(identifier: "zh_CN"))
        return "缓存命中 \(percentText)\n缓存读取 \(readTokens.formatted(format)) / 已记录输入 \(inputTokens.formatted(format)) Token"
    }
}
