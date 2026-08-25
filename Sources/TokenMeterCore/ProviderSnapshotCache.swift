import Foundation

public enum ProviderSnapshotCache {
    public static func merge(
        previous: [ProviderUsageSnapshot],
        refreshed: [ProviderUsageSnapshot],
        now: Date = Date()
    ) -> [ProviderUsageSnapshot] {
        let previousByProvider = Dictionary(uniqueKeysWithValues: previous.map { ($0.providerId, $0) })

        return refreshed.map { snapshot in
            let cached = previousByProvider[snapshot.providerId]
            // 窗口继承只对成功刷新的快照做：失败回退走下面整份缓存的分支，无需继承。
            let carried = snapshot.status == .ok && cached != nil
                ? carryOverVanishedWindows(snapshot, previous: cached!, now: now)
                : snapshot

            if carried.status == .ok,
               carried.resetCredits == nil,
               let cached,
               let resetCredits = cached.resetCredits {
                return ProviderUsageSnapshot(
                    providerId: carried.providerId,
                    displayName: carried.displayName,
                    status: carried.status,
                    fetchedAt: carried.fetchedAt,
                    summary: carried.summary,
                    message: carried.message,
                    groups: carried.groups,
                    resetCredits: resetCredits
                )
            }

            guard carried.status != .ok,
                  let cached,
                  !cached.groups.isEmpty else {
                return carried
            }

            return ProviderUsageSnapshot(
                providerId: cached.providerId,
                displayName: cached.displayName,
                status: .warning,
                fetchedAt: cached.fetchedAt,
                summary: cached.summary,
                message: carried.message,
                groups: cached.groups,
                resetCredits: cached.resetCredits
            )
        }
    }

    /// 「额度窗口消失」的两种语义必须区分：
    /// - **本轮数据缺失**：上一轮还有、这一轮突然没了、且其重置时刻未到 → 原样沿用
    ///   上一轮的数值与倒计时（不武断改写成用尽——实测 OpenCode Go 在额度尚剩 ~19%
    ///   时也可能整行漏渲染，标 100% 就是假警报）。下一轮抓到真实数据自然刷新。
    ///   缺了这一步环会凭空消失，表象与「无此窗口」（Codex 本就没有 5h）无法区分。
    /// - **无此窗口**：从未出现过 → 什么都不做，环本来就不该显示。
    /// 重置时刻已过仍不见该行 → 视作真的没有此窗口（或已重置），不再沿用。
    private static func carryOverVanishedWindows(
        _ refreshed: ProviderUsageSnapshot,
        previous: ProviderUsageSnapshot,
        now: Date
    ) -> ProviderUsageSnapshot {
        let presentIds = Set(refreshed.groups.flatMap { $0.items.map(\.id) })
        guard let primaryIndex = refreshed.groups.firstIndex(where: { $0.title == refreshed.displayName }),
              let previousPrimary = previous.groups.first(where: { $0.title == previous.displayName }) else {
            return refreshed
        }

        // 只沿用主组里带窗口时长的 quota；数值原样保留。resetAt 缺失时倾向沿用：
        // 无法证明过期，宁可显示上一轮数值也不制造「环消失→下一位顶进环位」的提升。
        // （真被删掉的窗口会一直沿用旧值直到用户报障，比静默的语义提升诚实。）
        let vanished = previousPrimary.items.filter { metric in
            metric.kind == .quota
                && metric.windowDurationMinutes != nil
                && !presentIds.contains(metric.id)
                && (metric.resetAt.map { $0 > now } ?? true)
        }
        guard !vanished.isEmpty else { return refreshed }

        var groups = refreshed.groups
        let primary = groups[primaryIndex]
        // 沿用的窗口按时长插回原位（5h 在 Weekly 前）；同长度的保持原相对顺序。
        let ordered = (primary.items + vanished).enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.windowDurationMinutes ?? Int.max
                let right = rhs.element.windowDurationMinutes ?? Int.max
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
        groups[primaryIndex] = UsageGroup(
            id: primary.id,
            title: primary.title,
            subtitle: primary.subtitle,
            items: ordered
        )
        return ProviderUsageSnapshot(
            providerId: refreshed.providerId,
            displayName: refreshed.displayName,
            status: refreshed.status,
            fetchedAt: refreshed.fetchedAt,
            summary: refreshed.summary,
            message: refreshed.message,
            groups: groups,
            resetCredits: refreshed.resetCredits
        )
    }
}

public enum ProviderSnapshotDiskCache {
    public static func read(from url: URL) throws -> [ProviderUsageSnapshot] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ProviderUsageSnapshot].self, from: Data(contentsOf: url))
    }

    public static func write(_ snapshots: [ProviderUsageSnapshot], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshots.filter { !$0.groups.isEmpty })
        try data.write(to: url, options: .atomic)
    }
}
