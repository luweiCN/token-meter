import XCTest
@testable import TokenMeterApp

/// 自动更新安装链的集成测试：真实 zip（ditto）、真实 sha256、真实解压与
/// 原子交换，仅注入 file:// 资产与假安装目录、关掉重启。
/// 核心断言：**任何校验失败时现有安装原封不动**。
final class UpdateInstallerTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// 造一个最小可辨识的 TokenMeter.app（Info.plist 版本 + 可执行占位）。
    private func makeFakeApp(at url: URL, version: String, marker: String) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true
        )
        let plist: [String: Any] = ["CFBundleShortVersionString": version, "CFBundleIdentifier": "com.luwei.tokenmeter"]
        try (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        try Data(marker.utf8).write(to: contents.appendingPathComponent("MacOS/TokenMeterApp"))
    }

    /// zip 假 app（与发布同工具 ditto -c -k --keepParent）并生成 shasum 格式校验文件。
    private func makeReleaseArtifacts(version: String) throws -> (zip: URL, checksum: URL) {
        let stage = sandbox.appendingPathComponent("stage-\(version)", isDirectory: true)
        let appURL = stage.appendingPathComponent("TokenMeter.app")
        try makeFakeApp(at: appURL, version: version, marker: "new-\(version)")

        let zipURL = sandbox.appendingPathComponent("TokenMeter-\(version)-arm64.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", appURL.path, zipURL.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        let hex = try UpdateInstaller.sha256Hex(of: zipURL)
        let checksumURL = sandbox.appendingPathComponent("TokenMeter-\(version)-arm64.zip.sha256")
        try Data("\(hex)  \(zipURL.lastPathComponent)\n".utf8).write(to: checksumURL)
        return (zipURL, checksumURL)
    }

    private func release(tag: String, zip: URL, checksum: URL) -> (UpdateChecker.Release, UpdateChecker.InstallableAssets) {
        let zipAsset = UpdateChecker.Asset(name: zip.lastPathComponent, downloadURL: zip, size: 1)
        let checksumAsset = UpdateChecker.Asset(name: checksum.lastPathComponent, downloadURL: checksum, size: 1)
        return (
            UpdateChecker.Release(tagName: tag, htmlURL: URL(string: "https://example.com")!, assets: [zipAsset, checksumAsset]),
            UpdateChecker.InstallableAssets(zip: zipAsset, checksum: checksumAsset)
        )
    }

    private func installedVersion(at url: URL) -> String? {
        (NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"]) as? String
    }

    func testFullChainReplacesInstallAtomically() async throws {
        let installURL = sandbox.appendingPathComponent("Installed/TokenMeter.app")
        try makeFakeApp(at: installURL, version: "1.0.0", marker: "old")
        let artifacts = try makeReleaseArtifacts(version: "1.1.0")
        let (rel, assets) = release(tag: "v1.1.0", zip: artifacts.zip, checksum: artifacts.checksum)

        try await UpdateInstaller.install(
            release: rel, assets: assets, installURL: installURL, relaunch: false, progress: { _ in }
        )

        XCTAssertEqual(installedVersion(at: installURL), "1.1.0")
        let marker = try String(
            contentsOf: installURL.appendingPathComponent("Contents/MacOS/TokenMeterApp"), encoding: .utf8
        )
        XCTAssertEqual(marker, "new-1.1.0")
    }

    func testChecksumMismatchLeavesInstallUntouched() async throws {
        let installURL = sandbox.appendingPathComponent("Installed/TokenMeter.app")
        try makeFakeApp(at: installURL, version: "1.0.0", marker: "old")
        let artifacts = try makeReleaseArtifacts(version: "1.1.0")
        // 篡改校验文件为一个不匹配的合法 hex
        try Data((String(repeating: "ab", count: 32) + "  x.zip\n").utf8).write(to: artifacts.checksum)
        let (rel, assets) = release(tag: "v1.1.0", zip: artifacts.zip, checksum: artifacts.checksum)

        do {
            try await UpdateInstaller.install(
                release: rel, assets: assets, installURL: installURL, relaunch: false, progress: { _ in }
            )
            XCTFail("expected checksumMismatch")
        } catch let error as UpdateInstaller.InstallError {
            guard case .checksumMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(installedVersion(at: installURL), "1.0.0")
    }

    func testVersionMismatchLeavesInstallUntouched() async throws {
        let installURL = sandbox.appendingPathComponent("Installed/TokenMeter.app")
        try makeFakeApp(at: installURL, version: "1.0.0", marker: "old")
        // zip 里是 1.1.0，但 release tag 声称 v1.2.0
        let artifacts = try makeReleaseArtifacts(version: "1.1.0")
        let (rel, assets) = release(tag: "v1.2.0", zip: artifacts.zip, checksum: artifacts.checksum)

        do {
            try await UpdateInstaller.install(
                release: rel, assets: assets, installURL: installURL, relaunch: false, progress: { _ in }
            )
            XCTFail("expected versionMismatch")
        } catch let error as UpdateInstaller.InstallError {
            guard case .versionMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(installedVersion(at: installURL), "1.0.0")
    }
}
