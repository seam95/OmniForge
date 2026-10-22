import Foundation
import Security

// MARK: - 条目命名

/// 翻译功能自有的 Keychain 条目命名（与提示词优化、用量监控等功能彼此独立）。
enum TranslationKeychain {
    static let service = "app.omniforge.translation"
    static let account = "api-key"
}

// MARK: - 错误

/// Keychain 操作失败；`errSecItemNotFound` 已按语义消化为「未配置」，不会抛此错。
enum TranslationKeychainError: Error, Equatable {
    case keychainUnavailable(OSStatus)
}

// MARK: - Security 调用注入点

/// Security 调用注入点：生产使用真实 `SecItem*`；测试注入闭包模拟，不触碰真实用户钥匙串。
struct TranslationKeychainOperations {
    /// 查询条目；返回状态与带 `kSecReturnData` 时的数据。
    var copyMatching: ([String: Any]) -> (status: OSStatus, data: Data?)
    /// 更新已存在条目。
    var update: (_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    /// 新增条目。
    var add: (_ attributes: [String: Any]) -> OSStatus
    /// 删除条目。
    var delete: (_ query: [String: Any]) -> OSStatus

    /// 生产实现：直接调用 Security 框架。
    static let live = TranslationKeychainOperations(
        copyMatching: { query in
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item as? Data)
        },
        update: { query, attributes in
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        },
        add: { attributes in
            SecItemAdd(attributes as CFDictionary, nil)
        },
        delete: { query in
            SecItemDelete(query as CFDictionary)
        }
    )
}

// MARK: - 实现

/// 翻译功能独立 API Key 存储：service=`app.omniforge.translation`，account=`api-key`。
///
/// 仅本设备可用（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`），不走 iCloud 同步。
/// 写入为 add or update 幂等；删除幂等；只有「条目不存在」返回 nil，其余读取失败向上抛错，
/// 避免把凭据读取失败误当成「匿名配置」。
final class TranslationKeychainStore: TranslationAPIKeyStoring {
    private let service: String
    private let account: String
    private let operations: TranslationKeychainOperations

    init(
        service: String = TranslationKeychain.service,
        account: String = TranslationKeychain.account,
        operations: TranslationKeychainOperations = .live
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
            // 条目不存在是「未配置 Key」，不是读取失败。
            if result.status == errSecItemNotFound { return nil }
            throw TranslationKeychainError.keychainUnavailable(result.status)
        }
        guard let data = result.data,
              let apiKey = String(data: data, encoding: .utf8),
              !apiKey.isEmpty else {
            // 数据存在但为空或不可解码：按不可读处理，不静默当成匿名配置。
            throw TranslationKeychainError.keychainUnavailable(errSecDecode)
        }
        return apiKey
    }

    func writeAPIKey(_ value: String) throws {
        // SecItemUpdate 的查询字典与 Delete 同构（class + service + account），不带 match limit。
        let existsStatus = operations.copyMatching(baseQuery).status
        switch existsStatus {
        case errSecSuccess:
            let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
            let status = operations.update(baseQuery, attributes)
            guard status == errSecSuccess else {
                throw TranslationKeychainError.keychainUnavailable(status)
            }
        case errSecItemNotFound:
            var attributes = baseQuery
            attributes[kSecValueData as String] = Data(value.utf8)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = operations.add(attributes)
            guard status == errSecSuccess else {
                throw TranslationKeychainError.keychainUnavailable(status)
            }
        default:
            throw TranslationKeychainError.keychainUnavailable(existsStatus)
        }
    }

    func deleteAPIKey() throws {
        let status = operations.delete(baseQuery)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TranslationKeychainError.keychainUnavailable(status)
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
