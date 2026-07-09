import Foundation

public enum UsageEventDeduplicator {
    /// 规则一（`byExactKey`）：`dedupeKey` 精确碰撞时保留 `tokensTotal` 最大的那条。
    ///   **本机全部去重都发生在这一遍**：Task 14e 起 Claude 的 `dedupeKey` 就是 `messageId`
    ///   本身，所以同一 messageId 的多条在这里合成一条。它们有两种成因：
    ///   1. 流式中间快照：同一次 API 调用（同 messageId、同 requestId）在响应流式返回时被
    ///      反复落盘，`output_tokens` 单调增长（如 4 → 4 → 559），`input`/cache 各档保持不变。
    ///      因此「tokensTotal 最大」就是「最终、最完整的一帧」。保留最早那条会记下最不完整的
    ///      快照、系统性少算 output（Task 14g 之前正是如此）。
    ///   2. resume / fork 造成的整条 assistant 响应跨多个 session 文件出现：这些是**逐字节相同**
    ///      的副本，tokensTotal 全相等，规则一退化为 observedAt / eventSeq 的确定性兜底。
    ///   Codex 的 `dedupeKey` 是 timestamp + 原始四元组，重复行也在这里合并（同样逐字节相同）。
    ///
    /// 规则二（`byMessageId` + `shouldReplace`）：退化到只按 `messageId` 二次归组。
    ///   **Task 14e 后本遍对现有任何来源都不再发生碰撞、`shouldReplace` 是死代码**：
    ///   - Claude：`dedupeKey == messageId`，故 `byExactKey` 里每个 messageId 恰好一条，
    ///     二次归组是 1:1，永不撞。
    ///   - Codex：`messageId` 为 nil → 落 passthrough（绝不能 `continue` 丢弃：见下）。
    ///   - omp / OpenCode：`dedupeKey` 为 nil，第一遍就进 passthrough，根本到不了这里。
    ///   保留它是防御性的（重复计费是静默错误，代价只有几行），且被单元测试覆盖；生产不触达。
    ///
    /// `shouldReplace` 里的 sidechain 让位分支更是双重死：finding 3 证明本机零个 messageId
    ///   同时出现在 top-level 与 subagents/ 文件（亦即零个跨越 main/sidechain），所以哪怕真在
    ///   这里撞了，两条也必是同一 chain，`isSidechain` 判别永不为真。
    ///
    /// 注意：`UNIQUE(source_file_id, event_seq)` **不是**防重复计数的机制。它只保证同一个
    /// (file, seq) 至多一行——让"同一行被原样重写"变幂等（崩溃恢复时的重放）。但被错误续读
    /// 而重读的行会拿到**新的** `event_seq`，直接绕过这个约束（见 scanner 的 whitespace 测试）。
    /// 真正防重复计数的是 `resumeOffset` 的正确性与 `parser_state` 的同步推进（见 LocalAgentScanner）。
    ///
    /// 输出按 `eventSeq` 升序，保证下游写入顺序确定。
    public static func deduplicate(_ events: [UsageEvent]) -> [UsageEvent] {
        var byExactKey: [String: UsageEvent] = [:]
        var passthrough: [UsageEvent] = []

        for event in events {
            guard let key = event.dedupeKey else {
                passthrough.append(event)
                continue
            }
            if let existing = byExactKey[key] {
                if replacesOnExactKey(existing, with: event) {
                    byExactKey[key] = event
                }
            } else {
                byExactKey[key] = event
            }
        }

        var byMessageId: [String: UsageEvent] = [:]
        for event in byExactKey.values {
            guard let messageId = event.messageId else {
                // Codex 事件带 dedupeKey 但 messageId 为 nil，会走到这里：放行是对的。
                // 它们已在第一遍 byExactKey 里按精确 key 去过重，此处只是不再按 messageId
                // 二次归组。绝不能 `continue`（丢弃）——那会凭空少算一条真实用量。
                // （Claude 事件 messageId 非 nil 且已作为 dedupeKey 唯一，走下面的分支且必不碰撞。）
                passthrough.append(event)
                continue
            }
            guard let existing = byMessageId[messageId] else {
                byMessageId[messageId] = event
                continue
            }
            if shouldReplace(existing, with: event) {
                byMessageId[messageId] = event
            }
        }

        return (Array(byMessageId.values) + passthrough).sorted { $0.eventSeq < $1.eventSeq }
    }

    /// 规则一的全序判别：`candidate` 是否应替换掉已在 `byExactKey` 里的 `existing`。
    ///
    /// 三级全序（tokensTotal 最大 → observedAt 最早 → eventSeq 最小）由 `UsageEventPrecedence`
    /// 统一裁决，`UsageEventWriter` 对已落库行去重时走同一个函数。规则曾被抄成两份、Task 14g
    /// 只修了这一份，因此绝不在这里复制排序逻辑。
    /// （`testTotalOrderIsLoadBearingAtEveryLevel` 用一个乱序输入守这三级：把高 seq 的并列帧
    /// 放在最小 seq 之前，删掉任一级就会挑错 winner。）
    private static func replacesOnExactKey(_ existing: UsageEvent, with candidate: UsageEvent) -> Bool {
        UsageEventPrecedence.candidateWins(candidate.precedenceFields, over: existing.precedenceFields)
    }

    /// 规则二的全序判别。**Task 14e 后无任何现有来源会触发它**（见 `deduplicate` 顶部注释）：
    /// 只被单元测试以"多个 dedupeKey 共享同一 messageId"这一合成形态覆盖，生产不触达。
    /// 因此这里【不】按 tokensTotal 决胜——keep-largest 只属于规则一（同 dedupeKey 的流式帧
    /// 在那里碰撞）；规则二的职责是「同 messageId、不同 dedupeKey」时的 sidechain 让位契约，
    /// 保留它是防御性的，且被单元测试当作通用契约覆盖。
    ///
    /// 全序而非偏序：少了 eventSeq 这一级，完全并列（同 isSidechain、同 observedAt）时
    /// 胜者取决于 Swift 每进程随机的哈希种子。靠 `.sorted()` 掩盖这种依赖
    /// 是可行的，但要求每个读代码的人记住「这里不能删排序」；把序补全则不需要。
    private static func shouldReplace(_ existing: UsageEvent, with candidate: UsageEvent) -> Bool {
        // sidechain 让位：finding 3 证明本机无 messageId 跨越 main/sidechain，此分支生产不触达，
        // 仅由单元测试作为通用契约覆盖。
        if existing.isSidechain != candidate.isSidechain {
            return existing.isSidechain && !candidate.isSidechain
        }
        if candidate.observedAt != existing.observedAt {
            return candidate.observedAt < existing.observedAt
        }
        return candidate.eventSeq < existing.eventSeq
    }
}
