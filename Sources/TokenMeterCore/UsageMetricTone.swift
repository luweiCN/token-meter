import Foundation

public enum UsageMetricTone: Equatable {
    case ok
    case warning
    case bad
    case muted
}

public enum UsageMetricToneResolver {
    public static func tone(for metric: UsageMetric?, now: Date = Date()) -> UsageMetricTone {
        guard let metric,
              metric.status == .ok,
              let remaining = metric.remainingPercent else {
            return .muted
        }

        if let resetAt = metric.resetAt,
           let windowDurationMinutes = metric.windowDurationMinutes,
           let tone = pacedWindowTone(
               remainingPercent: remaining,
               resetAt: resetAt,
               windowDurationMinutes: windowDurationMinutes,
               now: now
           ) {
            return tone
        }

        return usedPercentTone(100 - remaining)
    }

    private static func pacedWindowTone(
        remainingPercent: Double,
        resetAt: Date,
        windowDurationMinutes: Int,
        now: Date
    ) -> UsageMetricTone? {
        guard windowDurationMinutes > 0 else {
            return nil
        }

        let windowSeconds = Double(windowDurationMinutes * 60)
        let secondsLeft = resetAt.timeIntervalSince(now)
        guard secondsLeft > 0, secondsLeft <= windowSeconds else {
            return nil
        }

        let expectedUsed = (windowSeconds - secondsLeft) / windowSeconds * 100
        let actualUsed = 100 - remainingPercent
        let paceUnitMinutes = windowDurationMinutes >= 1_440 ? 1_440 : 60
        let paceAllowance = Double(paceUnitMinutes) / Double(windowDurationMinutes) * 100
        let greenAllowance = paceAllowance / 2
        let overPace = actualUsed - expectedUsed

        if overPace <= greenAllowance {
            return .ok
        }

        if overPace <= paceAllowance {
            return .warning
        }

        return .bad
    }

    private static func usedPercentTone(_ usedPercent: Double) -> UsageMetricTone {
        if usedPercent >= 80 {
            return .bad
        }

        if usedPercent >= 30 {
            return .warning
        }

        return .ok
    }
}
