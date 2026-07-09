import Foundation

public enum UsageEventDeduplicator {
    /// 规则一：`(messageId, requestId)` 精确碰撞时保留 `observedAt` 更早的那条。
    ///   同一条 assistant 响应会因 resume / fork 出现在多个 session 文件里。
    ///
    /// 规则二：退化到只按 `messageId` 匹配时，非 sidechain 永远胜过 sidechain，
    ///   与时间戳无关——sidechain 是副本，非 sidechain 是原件。
    ///
    ///   这条是对 ccusage issue #913 的防御性移植，**不是本机观察到的问题**：
    ///   本机 5,492 个 session 文件、334,941 行中，零个 messageId 出现在多个
    ///   requestId 下。保留它是因为重复计费是静默错误，而代价只有几行。
    ///
    /// 没有 `dedupeKey` 的事件（如 Codex）原样保留，它们的唯一性由数据库的
    /// `UNIQUE(source_file_id, event_seq)` 保证。
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
                if event.observedAt < existing.observedAt {
                    byExactKey[key] = event
                }
            } else {
                byExactKey[key] = event
            }
        }

        var byMessageId: [String: UsageEvent] = [:]
        for event in byExactKey.values {
            guard let messageId = event.messageId else { continue }
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

    /// 定义一个**全序**，使上面的 fold 与字典迭代顺序无关。
    ///
    /// 少了 eventSeq 这一级，完全并列（同 isSidechain、同 observedAt）时
    /// 胜者取决于 Swift 每进程随机的哈希种子。靠 `.sorted()` 掩盖这种依赖
    /// 是可行的，但要求每个读代码的人记住「这里不能删排序」；把序补全则不需要。
    private static func shouldReplace(_ existing: UsageEvent, with candidate: UsageEvent) -> Bool {
        // 非 sidechain 永远胜过 sidechain：sidechain 是副本，非 sidechain 是原件
        if existing.isSidechain != candidate.isSidechain {
            return existing.isSidechain && !candidate.isSidechain
        }
        if candidate.observedAt != existing.observedAt {
            return candidate.observedAt < existing.observedAt
        }
        return candidate.eventSeq < existing.eventSeq
    }
}
