import AppKit
import Foundation
import UserNotifications

/// 轻量更新检查（1.0 起）：查 GitHub Releases latest，比对当前版本。
/// 完整静默自动更新（Sparkle 式）需要签名/公证体系，等有分发证书再上；
/// 这里只负责「知道有新版 + 一键打开 release 页」。
enum UpdateChecker {
    static let releasesLatestURL = URL(string: "https://api.github.com/repos/luweiCN/token-meter/releases/latest")!
    static let lastAutoCheckKey = "updateLastAutoCheckAt"

    struct Asset: Equatable {
        let name: String
        let downloadURL: URL
        let size: Int
    }

    struct Release: Equatable {
        let tagName: String
        let htmlURL: URL
        let assets: [Asset]
    }

    /// 一键安装所需的资产对：zip + 伴随 .sha256（CI 流水线两者都会传）。
    struct InstallableAssets: Equatable {
        let zip: Asset
        let checksum: Asset
    }

    /// 当前机器架构（资产命名后缀口径：arm64 / x86_64→x64）。
    static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    /// 从 release 资产里挑出当前架构的 zip 与其 sha256；缺任一即 nil
    /// （调用方回退为打开下载页，不做无校验的自动安装）。
    static func installableAssets(from assets: [Asset], architecture: String = currentArchitecture) -> InstallableAssets? {
        guard let zip = assets.first(where: { $0.name.hasSuffix("-\(architecture).zip") }),
              let checksum = assets.first(where: { $0.name == zip.name + ".sha256" }) else {
            return nil
        }
        return InstallableAssets(zip: zip, checksum: checksum)
    }

    /// 解析 `shasum -a 256` 输出（`<64位hex>  <filename>`），返回小写 hex。
    static func parseChecksum(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let firstField = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first else {
            return nil
        }
        let hex = firstField.lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
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
        let assets: [Asset] = ((object["assets"] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let name = entry["name"] as? String,
                  let downloadText = entry["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadText) else {
                return nil
            }
            return Asset(name: name, downloadURL: downloadURL, size: entry["size"] as? Int ?? 0)
        }
        return Release(tagName: tag, htmlURL: url, assets: assets)
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

    /// 最近一次检查发现的新版（含可安装资产时右键菜单出现「更新到 vX.Y.Z」）。
    @MainActor
    static var pendingRelease: Release?

    /// 手动「检查更新…」：结果用 NSAlert 呈现（LSUIElement 应用需先激活抢焦点）。
    /// 有完整资产对（zip+sha256）时提供一键「立即更新」，否则回退开下载页。
    @MainActor
    static func checkInteractively() async {
        let release = await fetchLatestRelease()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if let release {
            if isNewer(remoteTag: release.tagName, than: currentVersion) {
                pendingRelease = release
                alert.messageText = "发现新版本 \(release.tagName)"
                if let assets = installableAssets(from: release.assets) {
                    alert.informativeText = "当前版本 \(currentVersion)。点击「立即更新」将在后台下载并校验（\(assets.zip.size / 1_048_576) MB），完成后自动重启。"
                    alert.addButton(withTitle: "立即更新")
                    alert.addButton(withTitle: "稍后")
                    if alert.runModal() == .alertFirstButtonReturn {
                        await runInstall(release: release, assets: assets)
                    }
                } else {
                    alert.informativeText = "当前版本 \(currentVersion)。该版本未附带本机架构的自动更新包，请前往下载页手动安装。"
                    alert.addButton(withTitle: "前往下载")
                    alert.addButton(withTitle: "稍后")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(release.htmlURL)
                    }
                }
            } else {
                pendingRelease = nil
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

    /// 一键更新执行：成功路径以 app 自动重启结束；失败弹错误、现有安装原样。
    @MainActor
    static func runInstall(release: Release, assets: InstallableAssets) async {
        do {
            try await UpdateInstaller.install(release: release, assets: assets) { _ in }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "更新失败"
            alert.informativeText = "\(error.localizedDescription)\n当前版本未受影响，可稍后重试或前往下载页手动更新。"
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
            await MainActor.run { pendingRelease = release }
            let content = UNMutableNotificationContent()
            content.title = "TokenMeter 有新版本 \(release.tagName)"
            content.body = "右键菜单栏图标 → 「更新到 \(release.tagName)」一键安装。"
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
