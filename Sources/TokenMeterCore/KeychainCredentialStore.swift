import Foundation
import Security

/// 应用内填写的供应商 API Key，存 macOS 钥匙串（generic password）。
/// account = providerId，service 固定。读取优先级由调用方决定
/// （约定：钥匙串（用户在 app 里显式填的）> 环境变量 / 凭证文件）。
public enum KeychainCredentialStore {
    public static let defaultService = "com.luwei.tokenmeter.provider-key"

    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
    }

    public static func hasToken(for providerId: String, service: String = defaultService) -> Bool {
        let query = baseQuery(providerId: providerId, service: service)
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// nil 或空串 = 删除该 provider 的 Key。
    public static func setToken(_ token: String?, for providerId: String, service: String = defaultService) throws {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let query = baseQuery(providerId: providerId, service: service)

        if trimmed.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
            return
        }

        let update = [kSecValueData as String: Data(trimmed.utf8)]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
        let attributes = query.merging(update) { _, new in new }
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    private static func baseQuery(providerId: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerId
        ]
    }
}
