import Foundation
import Security

// MARK: - 条目命名

/// 本应用自有 Keychain 条目命名。
enum OpencodeKeychain {
    static let service = "app.omniforge.opencode"
    static let account = "api-key"
}

// MARK: - 协议边界

/// OpenCode Go API Key 存取边界 — 读/写/删分离；write 为「add or update」幂等。
protocol OpencodeAPIKeyStoring: AnyObject {
    /// 只探测条目存在性，不读取密码（不触发钥匙串授权弹窗）。
    func hasAPIKey() -> Bool
    /// 读取 API Key；条目不存在 → nil。
    func readAPIKey() throws -> String?
    /// 写入 API Key（幂等：不存在则新增，存在则更新）。
    func writeAPIKey(_ apiKey: String) throws
    /// 删除 API Key（幂等：条目不存在视为成功）。
    func deleteAPIKey() throws
}

/// Keychain 操作失败；`errSecItemNotFound` 已按语义消化为「未配置」，不会抛此错。
enum OpencodeKeychainError: Error, Equatable {
    case keychainUnavailable(OSStatus)
}

// MARK: - Keychain 实现

/// 用 Security 框架读写本应用自有的 OpenCode Go API Key 条目。
/// 仅本设备可用（`AfterFirstUnlockThisDeviceOnly`），不上 iCloud 同步。
final class OpencodeKeychainAPIKeyStore: OpencodeAPIKeyStoring {
    private let service: String
    private let account: String
    private let operations: KeychainItemOperations

    init(
        service: String = OpencodeKeychain.service,
        account: String = OpencodeKeychain.account,
        operations: KeychainItemOperations = .live
    ) {
        self.service = service
        self.account = account
        self.operations = operations
    }

    func hasAPIKey() -> Bool {
        operations.copyMatching(baseQuery).status == errSecSuccess
    }

    func readAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let result = operations.copyMatching(query)
        guard result.status == errSecSuccess else {
            if result.status == errSecItemNotFound { return nil }
            throw OpencodeKeychainError.keychainUnavailable(result.status)
        }
        guard let data = result.data,
              let apiKey = String(data: data, encoding: .utf8),
              !apiKey.isEmpty else {
            throw OpencodeKeychainError.keychainUnavailable(errSecDecode)
        }
        return apiKey
    }

    func writeAPIKey(_ apiKey: String) throws {
        let existsStatus = operations.copyMatching(baseQuery).status

        switch existsStatus {
        case errSecSuccess:
            let attributes: [String: Any] = [kSecValueData as String: Data(apiKey.utf8)]
            let status = operations.update(baseQuery, attributes)
            guard status == errSecSuccess else {
                throw OpencodeKeychainError.keychainUnavailable(status)
            }
        case errSecItemNotFound:
            var attributes = baseQuery
            attributes[kSecValueData as String] = Data(apiKey.utf8)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = operations.add(attributes)
            guard status == errSecSuccess else {
                throw OpencodeKeychainError.keychainUnavailable(status)
            }
        default:
            throw OpencodeKeychainError.keychainUnavailable(existsStatus)
        }
    }

    func deleteAPIKey() throws {
        let status = operations.delete(baseQuery)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpencodeKeychainError.keychainUnavailable(status)
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
