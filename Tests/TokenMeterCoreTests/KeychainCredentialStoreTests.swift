import Security
import XCTest
@testable import TokenMeterCore

final class KeychainCredentialStoreTests: XCTestCase {
    /// 测试专用 service，绝不碰 app 真用的条目；tearDown 清理。
    private let service = "com.luwei.tokenmeter.tests.provider-key." + UUID().uuidString
    private let providerId = "zhipu-test"

    override func tearDownWithError() throws {
        try KeychainCredentialStore.setToken(nil, for: providerId, service: service)
    }

    private func storedValue() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerId,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func testSetReadUpdateAndDeleteRoundTrip() throws {
        XCTAssertNil(storedValue())
        XCTAssertFalse(KeychainCredentialStore.hasToken(for: providerId, service: service))

        try KeychainCredentialStore.setToken("  first-key\n", for: providerId, service: service)
        XCTAssertEqual(storedValue(), "first-key")
        XCTAssertTrue(KeychainCredentialStore.hasToken(for: providerId, service: service))

        // 覆盖写：同一 account 重复 set 不报 duplicate。
        try KeychainCredentialStore.setToken("second-key", for: providerId, service: service)
        XCTAssertEqual(storedValue(), "second-key")

        // 空串 = 删除。
        try KeychainCredentialStore.setToken("", for: providerId, service: service)
        XCTAssertNil(storedValue())
        XCTAssertFalse(KeychainCredentialStore.hasToken(for: providerId, service: service))
    }
}
