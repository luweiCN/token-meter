import AppKit
import Foundation
import TokenMeterCore
import UserNotifications

enum UsageNotificationAuthorizationState: Equatable {
    case unknown
    case notDetermined
    case denied
    case authorized
}

protocol UsageNotificationDelivering: AnyObject {
    func authorizationState() async -> UsageNotificationAuthorizationState
    func requestAuthorization() async -> UsageNotificationAuthorizationState
    func deliver(_ events: [UsageNotificationEvent])
    func openNotificationSettings()
}

final class UsageNotificationCenter: UsageNotificationDelivering {
    func authorizationState() async -> UsageNotificationAuthorizationState {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: Self.authorizationState(from: settings.authorizationStatus))
            }
        }
    }

    func requestAuthorization() async -> UsageNotificationAuthorizationState {
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
        }

        _ = try? await withCheckedThrowingContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        } as Bool

        return await authorizationState()
    }

    func deliver(_ events: [UsageNotificationEvent]) {
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = title(for: event)
            content.body = body(for: event)

            let request = UNNotificationRequest(
                identifier: "tokenmeter.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func title(for event: UsageNotificationEvent) -> String {
        switch event {
        case let .resetCreditsAdded(_, providerName, _, _):
            return "\(providerName) 新增重置卡"
        case let .quotaRefreshed(_, providerName, _):
            return "\(providerName) 额度已刷新"
        case let .quotaDepleted(_, providerName, _):
            return "\(providerName) 额度已用尽"
        }
    }

    private func body(for event: UsageNotificationEvent) -> String {
        switch event {
        case let .resetCreditsAdded(_, _, addedCount, totalCount):
            return "新增 \(addedCount) 张，当前共 \(totalCount) 张"
        case let .quotaRefreshed(_, _, metricLabel):
            return "\(metricLabel) 已恢复"
        case let .quotaDepleted(_, _, metricLabel):
            return "\(metricLabel) 已到 0%"
        }
    }

    private static func authorizationState(from status: UNAuthorizationStatus) -> UsageNotificationAuthorizationState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional:
            return .authorized
        @unknown default:
            return .unknown
        }
    }
}
