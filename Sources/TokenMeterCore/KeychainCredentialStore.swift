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

    public static func token(for providerId: String, service: String = defaultService) -> String? {
        var query = baseQuery(providerId: providerId, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    public static func hasToken(for providerId: String, service: String = defaultService) -> Bool {
        token(for: providerId, service: service) != nil
    }

    /// nil 或空串 = 删除该 provider 的 Key。
    public static func setToken(_ token: String?, for providerId: String, service: String = defaultService) throws {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let query = baseQuery(providerId: providerId, service: service)

        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(deleteStatus)
        }
        guard !trimmed.isEmpty else { return }

        var attributes = query
        attributes[kSecValueData as String] = Data(trimmed.utf8)
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
