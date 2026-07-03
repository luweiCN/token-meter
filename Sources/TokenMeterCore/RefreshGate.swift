import Foundation

public struct RefreshGate {
    public let minimumInterval: TimeInterval
    private var lastRefreshAt: Date?

    public init(minimumInterval: TimeInterval, lastRefreshAt: Date? = nil) {
        self.minimumInterval = minimumInterval
        self.lastRefreshAt = lastRefreshAt
    }

    public mutating func shouldRefresh(now: Date = Date()) -> Bool {
        guard let lastRefreshAt else {
            self.lastRefreshAt = now
            return true
        }

        guard now.timeIntervalSince(lastRefreshAt) >= minimumInterval else {
            return false
        }

        self.lastRefreshAt = now
        return true
    }
}
