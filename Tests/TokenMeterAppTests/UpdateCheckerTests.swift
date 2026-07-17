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
        {"tag_name": "v1.2.0", "html_url": "https://github.com/luweiCN/token-meter/releases/tag/v1.2.0", "draft": false, "prerelease": false}
        """
        let release = try XCTUnwrap(UpdateChecker.parseRelease(Data(json.utf8)))
        XCTAssertEqual(release.tagName, "v1.2.0")
        XCTAssertEqual(release.htmlURL.absoluteString, "https://github.com/luweiCN/token-meter/releases/tag/v1.2.0")
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
