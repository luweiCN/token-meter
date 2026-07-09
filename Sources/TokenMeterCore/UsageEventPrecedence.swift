import Foundation

/// 同一去重键（Claude 的 messageId、Codex 的 timestamp+四元组）发生碰撞时，谁胜出的**唯一**裁决点。
///
/// 两处共用：
///   - `UsageEventDeduplicator` —— 同一批解析出的事件在内存里折叠（全量扫描、单文件内多帧）。
///   - `UsageEventWriter` —— 候选事件与【已落库】的一行碰撞（续读路径：同一 messageId 的流式帧
///     分属先后两次扫描，内存去重看不到彼此，只有写库时才撞上）。
///
/// 曾经这条规则被抄了两份，Task 14g 只修了内存那一份、漏了写库那一份，于是续读路径上被截断的
/// 中间帧会永久顶掉最终帧。合成一个函数，杜绝规则再次分叉。
///
/// 全序（逐级决胜，任一级严格胜负即定）：
///   1. `tokensTotal` 更大者胜 —— 保留流式响应最终（最完整）帧。Claude 同一次调用（同 messageId、
///      同 requestId）在流式返回时反复落盘，`output_tokens` 单调增长（4 → 4 → 559），`input`/cache
///      各档不变，最早那帧是被截断的。「最完整」而非「最早」正是本次要落实到两端的核心。
///   2. 总量并列 → `observedEpochMs` 更早者胜 —— resume/fork 的逐字节副本走到这里，复刻
///      Task 14g 之前「保留最早」的确定性行为。
///   3. 时间也并列 → `eventSeq` 更小者胜 —— 否则完全并列时，胜者取决于事件到达顺序 /
///      Swift 每进程随机的哈希种子。补上这一级让胜者只由数据本身决定。
enum UsageEventPrecedence {
    /// 决胜所需的三个字段。`UsageEvent`（内存去重）与已落库行（写库去重）都能提供：
    /// 前者走计算属性，后者读 `tokens_total` / `observed_epoch_ms` / `event_seq` 三列。
    /// 用一个中间结构而不是两份比较逻辑，避免为省一次类型转换又把规则抄第二遍。
    struct Fields: Equatable {
        let tokensTotal: Int64
        let observedEpochMs: Int64
        let eventSeq: Int64
    }

    /// `candidate` 是否应取代 `existing`。见类型注释的三级全序。
    static func candidateWins(_ candidate: Fields, over existing: Fields) -> Bool {
        if candidate.tokensTotal != existing.tokensTotal {
            return candidate.tokensTotal > existing.tokensTotal
        }
        if candidate.observedEpochMs != existing.observedEpochMs {
            return candidate.observedEpochMs < existing.observedEpochMs
        }
        return candidate.eventSeq < existing.eventSeq
    }
}

extension UsageEvent {
    /// 内存去重侧的取值来源。`observedEpochMilliseconds` 与写库侧的 `observed_epoch_ms` 列同源同精度。
    var precedenceFields: UsageEventPrecedence.Fields {
        UsageEventPrecedence.Fields(
            tokensTotal: totalTokens,
            observedEpochMs: observedEpochMilliseconds,
            eventSeq: Int64(eventSeq)
        )
    }
}
