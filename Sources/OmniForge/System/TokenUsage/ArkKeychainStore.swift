import Foundation
import Security

// MARK: - 凭证模型

/// 火山引擎 OpenAPI 访问凭据（AK/SK）。
struct ArkCredentials: Equatable, Codable {
    var accessKeyId: String
    var secretAccessKey: String

    var isValid: Bool {
        !accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 条目命名

/// 本应用自有 Keychain 条目命名。
enum ArkKeychain {
    static let service = "app.omniforge.ark"
    static let account = "credentials"
}

// MARK: - 协议边界

/// 火山方舟凭据存取边界。
protocol ArkCredentialsStoring: AnyObject {
    /// 只探测条目存在性，不读取密码（不触发钥匙串授权弹窗）。
    func hasCredentials() -> Bool
    func readCredentials() throws -> ArkCredentials?
    func writeCredentials(_ credentials: ArkCredentials) throws
    func deleteCredentials() throws
}

/// Keychain 操作失败。
enum ArkKeychainError: Error, Equatable {
    case keychainUnavailable(OSStatus)
}

// MARK: - Keychain 实现

/// 用 Security 框架读写本应用自有的火山方舟 AK/SK 条目。
/// 仅本设备可用（`AfterFirstUnlockThisDeviceOnly`），不上 iCloud 同步。
final class ArkKeychainStore: ArkCredentialsStoring {
    private let service: String
    private let account: String
    private let operations: KeychainItemOperations

    init(
        service: String = ArkKeychain.service,
        account: String = ArkKeychain.account,
        operations: KeychainItemOperations = .live
    ) {
        self.service = service
        self.account = account
        self.operations = operations
    }

    func hasCredentials() -> Bool {
        operations.copyMatching(baseQuery).status == errSecSuccess
    }

    func readCredentials() throws -> ArkCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let result = operations.copyMatching(query)
        guard result.status == errSecSuccess else {
            if result.status == errSecItemNotFound { return nil }
            throw ArkKeychainError.keychainUnavailable(result.status)
        }
        guard let data = result.data,
              let credentials = try? JSONDecoder().decode(ArkCredentials.self, from: data),
              credentials.isValid else {
            if result.status == errSecDecode {
                throw ArkKeychainError.keychainUnavailable(errSecDecode)
            }
            return nil
        }
        return credentials
    }

    func writeCredentials(_ credentials: ArkCredentials) throws {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        let existsStatus = operations.copyMatching(baseQuery).status

        switch existsStatus {
        case errSecSuccess:
            let attributes: [String: Any] = [kSecValueData as String: data]
            let status = operations.update(baseQuery, attributes)
            guard status == errSecSuccess else {
                throw ArkKeychainError.keychainUnavailable(status)
            }
        case errSecItemNotFound:
            var attributes = baseQuery
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = operations.add(attributes)
            guard status == errSecSuccess else {
                throw ArkKeychainError.keychainUnavailable(status)
            }
        default:
            throw ArkKeychainError.keychainUnavailable(existsStatus)
        }
    }

    func deleteCredentials() throws {
        let status = operations.delete(baseQuery)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ArkKeychainError.keychainUnavailable(status)
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
