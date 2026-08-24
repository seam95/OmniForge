import Foundation
import Security

// MARK: - 条目命名

/// 本应用自有 Keychain 条目命名（对齐 `ClaudeKeychain` 的命名枚举风格）。
enum DeepSeekKeychain {
    static let service = "app.omniforge.deepseek"
    static let account = "api-key"
}

// MARK: - 协议边界

/// DeepSeek API Key 存取边界 — 读/写/删分离；write 为「add or update」幂等。
protocol DeepSeekAPIKeyStoring: AnyObject {
    /// 读取 API Key；条目不存在 → nil。
    func readAPIKey() throws -> String?
    /// 写入 API Key（幂等：不存在则新增，存在则更新）。
    func writeAPIKey(_ apiKey: String) throws
    /// 删除 API Key（幂等：条目不存在视为成功）。
    func deleteAPIKey() throws
}

/// Keychain 操作失败；`errSecItemNotFound` 已按语义消化为「未配置」，不会抛此错。
enum DeepSeekKeychainError: Error, Equatable {
    case keychainUnavailable(OSStatus)
}

// MARK: - Keychain 实现

/// 用 Security 框架读写本应用自有的 DeepSeek API Key 条目。
/// 仅本设备可用（`AfterFirstUnlockThisDeviceOnly`），不上 iCloud 同步。
final class DeepSeekKeychainAPIKeyStore: DeepSeekAPIKeyStoring {
    private let service: String
    private let account: String

    init(service: String = DeepSeekKeychain.service, account: String = DeepSeekKeychain.account) {
        self.service = service
        self.account = account
    }

    func readAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { return nil }
            throw DeepSeekKeychainError.keychainUnavailable(status)
        }
        guard let data = item as? Data,
              let apiKey = String(data: data, encoding: .utf8),
              !apiKey.isEmpty else {
            throw DeepSeekKeychainError.keychainUnavailable(errSecDecode)
        }
        return apiKey
    }

    func writeAPIKey(_ apiKey: String) throws {
        // SecItemUpdate 的查询字典与 Delete 同构（class + service + account），不带 match limit。
        let existsStatus = SecItemCopyMatching(baseQuery as CFDictionary, nil)

        switch existsStatus {
        case errSecSuccess:
            let attributes: [String: Any] = [kSecValueData as String: Data(apiKey.utf8)]
            let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else {
                throw DeepSeekKeychainError.keychainUnavailable(status)
            }
        case errSecItemNotFound:
            var attributes = baseQuery
            attributes[kSecValueData as String] = Data(apiKey.utf8)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw DeepSeekKeychainError.keychainUnavailable(status)
            }
        default:
            throw DeepSeekKeychainError.keychainUnavailable(existsStatus)
        }
    }

    func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeepSeekKeychainError.keychainUnavailable(status)
        }
    }

    // MARK: - 私有

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
