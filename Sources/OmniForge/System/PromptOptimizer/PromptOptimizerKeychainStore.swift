import Foundation
import Security

// MARK: - 条目命名

/// 提示词优化功能的自有 Keychain 条目命名（对齐 `DeepSeekKeychain` 的命名枚举风格）。
enum PromptOptimizerKeychain {
    static let service = "app.omniforge.prompt-optimizer"
    static let account = "api-key"
}

// MARK: - 协议边界

/// 提示词优化 API Key 存取边界 — 读/写/删分离；write 为「add or update」幂等。
protocol PromptOptimizerAPIKeyStoring: AnyObject {
    /// 读取 API Key；条目不存在 → nil。
    func readAPIKey() throws -> String?
    /// 写入 API Key（幂等：不存在则新增，存在则更新）。
    func writeAPIKey(_ apiKey: String) throws
    /// 删除 API Key（幂等：条目不存在视为成功）。
    func deleteAPIKey() throws
}

/// Keychain 操作失败；`errSecItemNotFound` 已按语义消化为「未配置」，不会抛此错。
enum PromptOptimizerKeychainError: Error, Equatable {
    case keychainUnavailable(OSStatus)
}

// MARK: - Keychain 实现

/// 用 Security 框架读写提示词优化的 API Key 条目（决策 D10：凭据只进 Keychain，绝不落 UserDefaults）。
/// 仅本设备可用（`AfterFirstUnlockThisDeviceOnly`），不上 iCloud 同步。
final class PromptOptimizerKeychainAPIKeyStore: PromptOptimizerAPIKeyStoring {
    private let service: String
    private let account: String
    private let operations: KeychainItemOperations

    init(
        service: String = PromptOptimizerKeychain.service,
        account: String = PromptOptimizerKeychain.account,
        operations: KeychainItemOperations = .live
    ) {
        self.service = service
        self.account = account
        self.operations = operations
    }

    func readAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let result = operations.copyMatching(query)
        guard result.status == errSecSuccess else {
            if result.status == errSecItemNotFound { return nil }
            throw PromptOptimizerKeychainError.keychainUnavailable(result.status)
        }
        guard let data = result.data,
              let apiKey = String(data: data, encoding: .utf8),
              !apiKey.isEmpty else {
            throw PromptOptimizerKeychainError.keychainUnavailable(errSecDecode)
        }
        return apiKey
    }

    func writeAPIKey(_ apiKey: String) throws {
        // SecItemUpdate 的查询字典与 Delete 同构（class + service + account），不带 match limit。
        let existsStatus = operations.copyMatching(baseQuery).status

        switch existsStatus {
        case errSecSuccess:
            let attributes: [String: Any] = [kSecValueData as String: Data(apiKey.utf8)]
            let status = operations.update(baseQuery, attributes)
            guard status == errSecSuccess else {
                throw PromptOptimizerKeychainError.keychainUnavailable(status)
            }
        case errSecItemNotFound:
            var attributes = baseQuery
            attributes[kSecValueData as String] = Data(apiKey.utf8)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = operations.add(attributes)
            guard status == errSecSuccess else {
                throw PromptOptimizerKeychainError.keychainUnavailable(status)
            }
        default:
            throw PromptOptimizerKeychainError.keychainUnavailable(existsStatus)
        }
    }

    func deleteAPIKey() throws {
        let status = operations.delete(baseQuery)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PromptOptimizerKeychainError.keychainUnavailable(status)
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
