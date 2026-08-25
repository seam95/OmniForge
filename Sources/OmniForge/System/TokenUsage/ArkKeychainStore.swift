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

    init(service: String = ArkKeychain.service, account: String = ArkKeychain.account) {
        self.service = service
        self.account = account
    }

    func readCredentials() throws -> ArkCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { return nil }
            throw ArkKeychainError.keychainUnavailable(status)
        }
        guard let data = item as? Data,
              let credentials = try? JSONDecoder().decode(ArkCredentials.self, from: data),
              credentials.isValid else {
            if status == errSecDecode {
                throw ArkKeychainError.keychainUnavailable(errSecDecode)
            }
            return nil
        }
        return credentials
    }

    func writeCredentials(_ credentials: ArkCredentials) throws {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        let existsStatus = SecItemCopyMatching(baseQuery as CFDictionary, nil)

        switch existsStatus {
        case errSecSuccess:
            let attributes: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else {
                throw ArkKeychainError.keychainUnavailable(status)
            }
        case errSecItemNotFound:
            var attributes = baseQuery
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw ArkKeychainError.keychainUnavailable(status)
            }
        default:
            throw ArkKeychainError.keychainUnavailable(existsStatus)
        }
    }

    func deleteCredentials() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
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
