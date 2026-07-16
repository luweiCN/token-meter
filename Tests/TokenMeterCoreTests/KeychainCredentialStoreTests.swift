import XCTest
@testable import TokenMeterCore

final class KeychainCredentialStoreTests: XCTestCase {
    /// 测试专用 service，绝不碰 app 真用的条目；tearDown 清理。
    private let service = "com.luwei.tokenmeter.tests.provider-key"
    private let providerId = "zhipu-test"

    override func tearDownWithError() throws {
        try KeychainCredentialStore.setToken(nil, for: providerId, service: service)
    }

    func testSetReadUpdateAndDeleteRoundTrip() throws {
        XCTAssertNil(KeychainCredentialStore.token(for: providerId, service: service))
        XCTAssertFalse(KeychainCredentialStore.hasToken(for: providerId, service: service))

        try KeychainCredentialStore.setToken("  first-key\n", for: providerId, service: service)
        XCTAssertEqual(KeychainCredentialStore.token(for: providerId, service: service), "first-key")
        XCTAssertTrue(KeychainCredentialStore.hasToken(for: providerId, service: service))

        // 覆盖写：同一 account 重复 set 不报 duplicate。
        try KeychainCredentialStore.setToken("second-key", for: providerId, service: service)
        XCTAssertEqual(KeychainCredentialStore.token(for: providerId, service: service), "second-key")

        // 空串 = 删除。
        try KeychainCredentialStore.setToken("", for: providerId, service: service)
        XCTAssertNil(KeychainCredentialStore.token(for: providerId, service: service))
        XCTAssertFalse(KeychainCredentialStore.hasToken(for: providerId, service: service))
    }
}
