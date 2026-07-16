import Foundation

public enum UsageNotificationEvent: Equatable {
    case resetCreditsAdded(providerId: String, providerName: String, addedCount: Int, totalCount: Int)
    case resetCreditsConsumed(providerId: String, providerName: String, removedCount: Int, remainingCount: Int)
    case quotaRefreshed(providerId: String, providerName: String, metricLabel: String)
    case quotaDepleted(providerId: String, providerName: String, metricLabel: String)
    case quotaThresholdCrossed(providerId: String, providerName: String, metricLabel: String, usedPercent: Int, thresholdPercent: Int)
}

public enum UsageNotificationEventDetector {
    /// usedThresholdPercent：设置页的告警阈值（0 = 关闭）。用量向上跨过阈值时发
    /// quotaThresholdCrossed；只在跨越那一次发，不随每轮刷新重复。
    public static func events(
        previous: [ProviderUsageSnapshot],
        current: [ProviderUsageSnapshot],
        usedThresholdPercent: Int = 0
    ) -> [UsageNotificationEvent] {
        let previousByProvider = Dictionary(uniqueKeysWithValues: previous.map { ($0.providerId, $0) })

        return current.flatMap { currentSnapshot -> [UsageNotificationEvent] in
            guard currentSnapshot.status == .ok,
                  let previousSnapshot = previousByProvider[currentSnapshot.providerId],
                  previousSnapshot.status == .ok else {
                return []
            }

            return resetCreditEvents(previous: previousSnapshot, current: currentSnapshot)
                + quotaEvents(previous: previousSnapshot, current: currentSnapshot, usedThresholdPercent: usedThresholdPercent)
        }
    }

    private static func resetCreditEvents(
        previous: ProviderUsageSnapshot,
        current: ProviderUsageSnapshot
    ) -> [UsageNotificationEvent] {
        guard let previousCount = previous.resetCredits?.availableCount,
              let currentCount = current.resetCredits?.availableCount,
              currentCount != previousCount else {
            return []
        }

        if currentCount > previousCount {
            return [
                .resetCreditsAdded(
                    providerId: current.providerId,
                    providerName: current.displayName,
                    addedCount: currentCount - previousCount,
                    totalCount: currentCount
                )
            ]
        }

        // 可用卡变少 = 被自动消耗或过期。用户要能察觉「额度烧掉了一张卡」。
        return [
            .resetCreditsConsumed(
                providerId: current.providerId,
                providerName: current.displayName,
                removedCount: previousCount - currentCount,
                remainingCount: currentCount
            )
        ]
    }

    private static func quotaEvents(
        previous: ProviderUsageSnapshot,
        current: ProviderUsageSnapshot,
        usedThresholdPercent: Int
    ) -> [UsageNotificationEvent] {
        let previousMetrics = Dictionary(uniqueKeysWithValues: notificationMetrics(in: previous).map { ($0.metric.id, $0) })

        return notificationMetrics(in: current).flatMap { currentEntry -> [UsageNotificationEvent] in
            guard currentEntry.metric.status == .ok,
                  let previousEntry = previousMetrics[currentEntry.metric.id],
                  previousEntry.metric.status == .ok,
                  let previousRemaining = previousEntry.metric.remainingPercent,
                  let currentRemaining = currentEntry.metric.remainingPercent else {
                return []
            }

            if previousRemaining > 0, currentRemaining <= 0 {
                return [
                    .quotaDepleted(
                        providerId: current.providerId,
                        providerName: current.displayName,
                        metricLabel: currentEntry.label
                    )
                ]
            }

            // 用量向上跨过阈值（且没到 0——到 0 由 depleted 独占，不双发）。
            if usedThresholdPercent > 0 {
                let previousUsed = 100 - previousRemaining
                let currentUsed = 100 - currentRemaining
                let threshold = Double(usedThresholdPercent)
                if previousUsed < threshold, currentUsed >= threshold, currentRemaining > 0 {
                    return [
                        .quotaThresholdCrossed(
                            providerId: current.providerId,
                            providerName: current.displayName,
                            metricLabel: currentEntry.label,
                            usedPercent: Int(currentUsed.rounded()),
                            thresholdPercent: usedThresholdPercent
                        )
                    ]
                }
            }

            if previousRemaining < 95, currentRemaining >= 99 {
                if let previousResetAt = previousEntry.metric.resetAt,
                   let currentResetAt = currentEntry.metric.resetAt,
                   currentResetAt <= previousResetAt {
                    return []
                }

                return [
                    .quotaRefreshed(
                        providerId: current.providerId,
                        providerName: current.displayName,
                        metricLabel: currentEntry.label
                    )
                ]
            }

            return []
        }
    }

    private static func notificationMetrics(in snapshot: ProviderUsageSnapshot) -> [(metric: UsageMetric, label: String)] {
        snapshot.groups.flatMap { group in
            group.items.map { metric in
                let label = group.title == snapshot.displayName ? metric.label : "\(group.title) \(metric.label)"
                return (metric: metric, label: label)
            }
        }
    }
}
