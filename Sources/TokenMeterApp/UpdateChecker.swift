import AppKit
import Foundation
import UserNotifications

/// 轻量更新检查（1.0 起）：查 GitHub Releases latest，比对当前版本。
/// 完整静默自动更新（Sparkle 式）需要签名/公证体系，等有分发证书再上；
/// 这里只负责「知道有新版 + 一键打开 release 页」。
enum UpdateChecker {
    static let releasesLatestURL = URL(string: "https://api.github.com/repos/luweiCN/token-meter/releases/latest")!
    static let lastAutoCheckKey = "updateLastAutoCheckAt"

    struct Release: Equatable {
        let tagName: String
        let htmlURL: URL
    }

    /// tag（可带 v 前缀）是否比当前版本新。非纯数字段的 tag（预发布）一律不算。
    static func isNewer(remoteTag: String, than currentVersion: String) -> Bool {
        guard let remote = numericParts(remoteTag) else { return false }
        guard let current = numericParts(currentVersion) else { return true }
        let count = max(remote.count, current.count)
        for index in 0..<count {
            let r = index < remote.count ? remote[index] : 0
            let c = index < current.count ? current[index] : 0
            if r != c { return r > c }
        }
        return false
    }

    private static func numericParts(_ version: String) -> [Int]? {
        let stripped = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = stripped.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        return numbers.isEmpty ? nil : numbers
    }

    /// GitHub /releases/latest 响应 → Release。draft/prerelease/坏数据一律 nil。
    static func parseRelease(_ data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["draft"] as? Bool == false,
              object["prerelease"] as? Bool == false,
              let tag = object["tag_name"] as? String,
              let urlText = object["html_url"] as? String,
              let url = URL(string: urlText) else {
            return nil
        }
        return Release(tagName: tag, htmlURL: url)
    }

    /// 静默检查节流：24 小时一次。
    static func shouldAutoCheck(lastCheckedAt: Date?, now: Date = Date()) -> Bool {
        guard let lastCheckedAt else { return true }
        return now.timeIntervalSince(lastCheckedAt) > 86_400
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// 拉取 latest release；网络/解析失败返回 nil（调用方决定怎么呈现）。
    static func fetchLatestRelease() async -> Release? {
        var request = URLRequest(url: releasesLatestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        return parseRelease(data)
    }

    /// 手动「检查更新…」：结果用 NSAlert 呈现（LSUIElement 应用需先激活抢焦点）。
    @MainActor
    static func checkInteractively() async {
        let release = await fetchLatestRelease()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if let release {
            if isNewer(remoteTag: release.tagName, than: currentVersion) {
                alert.messageText = "发现新版本 \(release.tagName)"
                alert.informativeText = "当前版本 \(currentVersion)。前往下载页安装新版本。"
                alert.addButton(withTitle: "前往下载")
                alert.addButton(withTitle: "稍后")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(release.htmlURL)
                }
            } else {
                alert.messageText = "已是最新版本"
                alert.informativeText = "当前版本 \(currentVersion) 就是最新发布版。"
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        } else {
            alert.messageText = "检查更新失败"
            alert.informativeText = "无法连接 GitHub Releases，请稍后再试。"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    /// 启动静默检查（24h 节流）：有新版发一条系统通知，点击打开下载页由
    /// 通知中心默认行为承接（附 URL 进 userInfo 供将来扩展）。
    static func autoCheckIfDue(defaults: UserDefaults = .standard) {
        guard shouldAutoCheck(lastCheckedAt: defaults.object(forKey: lastAutoCheckKey) as? Date) else {
            return
        }
        defaults.set(Date(), forKey: lastAutoCheckKey)
        Task {
            guard let release = await fetchLatestRelease(),
                  isNewer(remoteTag: release.tagName, than: currentVersion) else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "TokenMeter 有新版本 \(release.tagName)"
            content.body = "右键菜单栏图标 → 检查更新，或前往 GitHub Releases 下载。"
            content.userInfo = ["releaseURL": release.htmlURL.absoluteString]
            let request = UNNotificationRequest(
                identifier: "tokenmeter.update.\(release.tagName)",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
