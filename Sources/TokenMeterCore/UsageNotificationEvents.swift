import Foundation

public enum UsageNotificationEvent: Equatable {
    case resetCreditsAdded(providerId: String, providerName: String, addedCount: Int, totalCount: Int)
    case quotaRefreshed(providerId: String, providerName: String, metricLabel: String)
    case quotaDepleted(providerId: String, providerName: String, metricLabel: String)
}

public enum UsageNotificationEventDetector {
    public static func events(
        previous: [ProviderUsageSnapshot],
        current: [ProviderUsageSnapshot]
    ) -> [UsageNotificationEvent] {
        let previousByProvider = Dictionary(uniqueKeysWithValues: previous.map { ($0.providerId, $0) })

        return current.flatMap { currentSnapshot -> [UsageNotificationEvent] in
            guard currentSnapshot.status == .ok,
                  let previousSnapshot = previousByProvider[currentSnapshot.providerId],
                  previousSnapshot.status == .ok else {
                return []
            }

            return resetCreditEvents(previous: previousSnapshot, current: currentSnapshot)
                + quotaEvents(previous: previousSnapshot, current: currentSnapshot)
        }
    }

    private static func resetCreditEvents(
        previous: ProviderUsageSnapshot,
        current: ProviderUsageSnapshot
    ) -> [UsageNotificationEvent] {
        guard let previousCount = previous.resetCredits?.availableCount,
              let currentCount = current.resetCredits?.availableCount,
              currentCount > previousCount else {
            return []
        }

        return [
            .resetCreditsAdded(
                providerId: current.providerId,
                providerName: current.displayName,
                addedCount: currentCount - previousCount,
                totalCount: currentCount
            )
        ]
    }

    private static func quotaEvents(
        previous: ProviderUsageSnapshot,
        current: ProviderUsageSnapshot
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
