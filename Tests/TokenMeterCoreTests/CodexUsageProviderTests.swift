import XCTest
@testable import TokenMeterCore

final class CodexUsageProviderTests: XCTestCase {
    func testExecutableSearchPathIncludesCommonNodeAndCodexInstallLocations() throws {
        // TokenMeter 常驻进程由 LaunchAgent 拉起，继承的 PATH 只有
        // /usr/bin:/bin:/usr/sbin:/sbin —— 既没有 node（常装在 .volta/bin
        // 之类的地方），也没有 codex 本体（常装在 .local/bin）。spawn 子
        // 进程时必须显式给一条更完整的 PATH，否则 `env node` 直接找不到人。
        let path = CodexUsageProvider.executableSearchPath(homeDirectory: "/Users/fakehome")

        XCTAssertTrue(path.contains("/Users/fakehome/.local/bin"))
        XCTAssertTrue(path.contains("/Users/fakehome/.volta/bin"))
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.contains("/usr/local/bin"))
        XCTAssertTrue(path.contains("/usr/bin"))
    }
}
