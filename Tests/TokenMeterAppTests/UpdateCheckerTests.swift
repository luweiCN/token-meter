import XCTest
@testable import TokenMeterApp

final class UpdateCheckerTests: XCTestCase {
    // MARK: - 版本比较（tag 剥 v 前缀，按数字段比较）

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer(remoteTag: "v1.0.1", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer(remoteTag: "v1.1.0", than: "1.0.9"))
        XCTAssertTrue(UpdateChecker.isNewer(remoteTag: "2.0.0", than: "1.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer(remoteTag: "v1.0.10", than: "1.0.9"))
        XCTAssertFalse(UpdateChecker.isNewer(remoteTag: "v1.0.0", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer(remoteTag: "v0.9.0", than: "1.0.0"))
        // 段数不齐：缺段按 0
        XCTAssertTrue(UpdateChecker.isNewer(remoteTag: "v1.0.0.1", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer(remoteTag: "v1.0", than: "1.0.0"))
        // 非数字 tag 不算新版本（预发布等直接忽略）
        XCTAssertFalse(UpdateChecker.isNewer(remoteTag: "v1.0.1-beta", than: "1.0.0"))
    }

    // MARK: - GitHub latest release 响应解析

    func testParsesLatestRelease() throws {
        let json = """
        {"tag_name": "v1.2.0", "html_url": "https://github.com/luweiCN/token-meter/releases/tag/v1.2.0", "draft": false, "prerelease": false,
         "assets": [
           {"name": "TokenMeter-1.2.0-arm64.zip", "browser_download_url": "https://example.com/TokenMeter-1.2.0-arm64.zip", "size": 100},
           {"name": "TokenMeter-1.2.0-arm64.zip.sha256", "browser_download_url": "https://example.com/TokenMeter-1.2.0-arm64.zip.sha256", "size": 93}
         ]}
        """
        let release = try XCTUnwrap(UpdateChecker.parseRelease(Data(json.utf8)))
        XCTAssertEqual(release.tagName, "v1.2.0")
        XCTAssertEqual(release.htmlURL.absoluteString, "https://github.com/luweiCN/token-meter/releases/tag/v1.2.0")
        XCTAssertEqual(release.assets.map(\.name), ["TokenMeter-1.2.0-arm64.zip", "TokenMeter-1.2.0-arm64.zip.sha256"])
    }

    /// 无 assets 字段的响应仍可解析（更新提示照常，只是没有一键安装）。
    func testParsesReleaseWithoutAssets() throws {
        let json = """
        {"tag_name": "v1.2.0", "html_url": "https://example.com", "draft": false, "prerelease": false}
        """
        let release = try XCTUnwrap(UpdateChecker.parseRelease(Data(json.utf8)))
        XCTAssertEqual(release.assets, [])
    }

    // MARK: - 一键安装的资产选择（zip + 伴随 sha256 都在才可自动装）

    func testSelectsInstallableAssetPairForCurrentArch() throws {
        let assets = [
            UpdateChecker.Asset(name: "TokenMeter-1.2.0-x64.zip", downloadURL: URL(string: "https://e.com/x")!, size: 1),
            UpdateChecker.Asset(name: "TokenMeter-1.2.0-arm64.zip", downloadURL: URL(string: "https://e.com/a")!, size: 1),
            UpdateChecker.Asset(name: "TokenMeter-1.2.0-arm64.zip.sha256", downloadURL: URL(string: "https://e.com/s")!, size: 1)
        ]
        let pair = try XCTUnwrap(UpdateChecker.installableAssets(from: assets, architecture: "arm64"))
        XCTAssertEqual(pair.zip.name, "TokenMeter-1.2.0-arm64.zip")
        XCTAssertEqual(pair.checksum.name, "TokenMeter-1.2.0-arm64.zip.sha256")

        // 缺 sha256 → 不提供一键安装（回退开下载页）
        XCTAssertNil(UpdateChecker.installableAssets(from: Array(assets.prefix(2)), architecture: "arm64"))
        // 无对应架构 zip → nil
        XCTAssertNil(UpdateChecker.installableAssets(from: assets, architecture: "riscv"))
    }

    // MARK: - sha256 文件解析（`<hex>  <filename>` 格式）

    func testParsesChecksumFile() {
        let text = "ab34cd" + String(repeating: "0", count: 58) + "  TokenMeter-1.2.0-arm64.zip\n"
        XCTAssertEqual(
            UpdateChecker.parseChecksum(Data(text.utf8))?.lowercased(),
            ("ab34cd" + String(repeating: "0", count: 58)).lowercased()
        )
        XCTAssertNil(UpdateChecker.parseChecksum(Data("not a checksum line".utf8)))
        XCTAssertNil(UpdateChecker.parseChecksum(Data()))
    }

    func testIgnoresDraftAndPrerelease() throws {
        let draft = """
        {"tag_name": "v9.9.9", "html_url": "https://example.com", "draft": true, "prerelease": false}
        """
        XCTAssertNil(UpdateChecker.parseRelease(Data(draft.utf8)))
        let pre = """
        {"tag_name": "v9.9.9", "html_url": "https://example.com", "draft": false, "prerelease": true}
        """
        XCTAssertNil(UpdateChecker.parseRelease(Data(pre.utf8)))
    }

    func testMalformedResponseYieldsNil() {
        XCTAssertNil(UpdateChecker.parseRelease(Data("not json".utf8)))
        XCTAssertNil(UpdateChecker.parseRelease(Data("{}".utf8)))
    }

    // MARK: - 静默检查节流（24h）

    func testThrottleWindow() {
        let now = Date()
        XCTAssertTrue(UpdateChecker.shouldAutoCheck(lastCheckedAt: nil, now: now))
        XCTAssertFalse(UpdateChecker.shouldAutoCheck(lastCheckedAt: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(UpdateChecker.shouldAutoCheck(lastCheckedAt: now.addingTimeInterval(-86_401), now: now))
    }
}
