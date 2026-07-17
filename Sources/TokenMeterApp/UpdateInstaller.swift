import AppKit
import CryptoKit
import Foundation
import UserNotifications

/// 一键自动更新：下载 Release 资产 → sha256 校验 → 解压验证 → 原子替换自身 → 重启。
/// 安全顺序是这里的全部要点：**所有校验通过之前绝不触碰现有安装**；替换用同卷
/// rename 交换，失败时把旧版换回来。传输安全靠 GitHub 的 TLS + CI 生成的 sha256。
enum UpdateInstaller {
    enum InstallError: LocalizedError {
        case downloadFailed(String)
        case checksumMismatch
        case extractionFailed
        case versionMismatch(expected: String, found: String)
        case swapFailed(String)

        var errorDescription: String? {
            switch self {
            case let .downloadFailed(what): return "下载失败：\(what)"
            case .checksumMismatch: return "校验失败：下载文件的 SHA-256 与发布记录不符"
            case .extractionFailed: return "解压失败：更新包不完整"
            case let .versionMismatch(expected, found): return "版本不符：更新包是 \(found)，期望 \(expected)"
            case let .swapFailed(what): return "替换应用失败：\(what)"
            }
        }
    }

    /// 流式 SHA-256（185MB 包不整块进内存）。
    static func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return SHA256.Digest.hexString(hasher.finalize())
    }

    /// 解压出的 app 必须与 release tag 同版本（防错包/搬运错误）。
    static func verifyExtractedVersion(appURL: URL, expectedTag: String) throws {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        let expected = expectedTag.hasPrefix("v") ? String(expectedTag.dropFirst()) : expectedTag
        guard let plist = NSDictionary(contentsOf: plistURL),
              let found = plist["CFBundleShortVersionString"] as? String else {
            throw InstallError.extractionFailed
        }
        guard found == expected else {
            throw InstallError.versionMismatch(expected: expected, found: found)
        }
    }

    /// 完整安装流程。progress 回调用于弹窗文案（主线程外调用方自行调度）。
    /// installURL/relaunch 可注入：集成测试用假安装目录跑完整链路（不重启）。
    static func install(
        release: UpdateChecker.Release,
        assets: UpdateChecker.InstallableAssets,
        installURL: URL = Bundle.main.bundleURL,
        relaunch: Bool = true,
        progress: @escaping (String) -> Void
    ) async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmeter-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // 1. 下载 sha256（小）与 zip（大）。file:// 资产（测试）无 HTTP 状态码，跳过状态检查。
        progress("正在下载校验文件…")
        guard let (checksumData, checksumResponse) = try? await URLSession.shared.data(from: assets.checksum.downloadURL),
              httpOK(checksumResponse),
              let expectedHex = UpdateChecker.parseChecksum(checksumData) else {
            throw InstallError.downloadFailed("无法获取校验文件")
        }

        progress("正在下载更新包（\(assets.zip.size / 1_048_576) MB）…")
        guard let (tempZip, zipResponse) = try? await URLSession.shared.download(from: assets.zip.downloadURL),
              httpOK(zipResponse) else {
            throw InstallError.downloadFailed("无法下载更新包")
        }
        let zipURL = workDir.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: tempZip, to: zipURL)

        // 2. 校验。
        progress("正在校验…")
        guard try sha256Hex(of: zipURL) == expectedHex else {
            throw InstallError.checksumMismatch
        }

        // 3. 解压 + 版本核验（ditto 保留资源叉/权限，与打包同工具）。
        progress("正在解压…")
        let extractDir = workDir.appendingPathComponent("extracted", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipURL.path, extractDir.path]
        try ditto.run()
        ditto.waitUntilExit()
        let newApp = extractDir.appendingPathComponent("TokenMeter.app")
        guard ditto.terminationStatus == 0,
              FileManager.default.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/TokenMeterApp").path) else {
            throw InstallError.extractionFailed
        }
        try verifyExtractedVersion(appURL: newApp, expectedTag: release.tagName)

        // 4. 原子替换自身：旧版先挪到工作目录（同卷 move 快），新版进位；
        //    进位失败则把旧版挪回来——任何时刻磁盘上都有一份可启动的 app。
        progress("正在安装…")
        let parked = workDir.appendingPathComponent("previous.app")
        do {
            try FileManager.default.moveItem(at: installURL, to: parked)
        } catch {
            throw InstallError.swapFailed("移出旧版本被拒绝（\(error.localizedDescription)）")
        }
        do {
            try FileManager.default.moveItem(at: newApp, to: installURL)
        } catch {
            try? FileManager.default.moveItem(at: parked, to: installURL)
            throw InstallError.swapFailed(error.localizedDescription)
        }

        // 5. 旧主界面（Electron）引用的 Resources/Electron 已被整目录替换，
        //    留着必然状态错乱/白屏（install-app.sh 同款处理）——一并关掉。
        let killElectron = Process()
        killElectron.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killElectron.arguments = ["-f", "\(installURL.path)/Contents/Resources/Electron"]
        try? killElectron.run()
        killElectron.waitUntilExit()

        // 6. 重启：先发系统通知预告（不打断、不等待），再由分离的 shell
        //    等本进程退出后 open 新版（孤儿进程由 launchd 收养）。
        guard relaunch else { return }
        progress("即将重启…")
        let content = UNMutableNotificationContent()
        content.title = "TokenMeter 已更新到 \(release.tagName)"
        content.body = "正在自动重启以完成更新。"
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "tokenmeter.updated.\(release.tagName)", content: content, trigger: nil)
        )
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", "sleep 1; /usr/bin/open \"\(installURL.path)\""]
        try? relauncher.run()
        await MainActor.run {
            NSApp.terminate(nil)
        }
    }

    /// http(s) 要求 200；file://（测试注入）没有 HTTPURLResponse，视为成功。
    private static func httpOK(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        return http.statusCode == 200
    }
}

extension SHA256.Digest {
    static func hexString(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
