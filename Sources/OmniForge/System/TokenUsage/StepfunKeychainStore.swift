import Foundation
import Security

// MARK: - 条目命名

/// StepFun Oasis-Token 的 Keychain 条目。
enum StepfunKeychain {
    static let service = "app.omniforge.stepfun"
    static let account = "oasis-token"
}

// MARK: - 协议边界

/// StepFun Oasis-Token 存取边界 — 读/写/删分离；write 为「add or update」幂等。
protocol StepfunTokenStoring: AnyObject {
    func readToken() throws -> String?
    func writeToken(_ token: String) throws
    func deleteToken() throws
}

enum StepfunKeychainError: Error, Equatable {
    case keychainUnavailable(OSStatus)
}

// MARK: - Keychain 实现

/// 用 Security 框架读写 StepFun 的 Oasis-Token。
/// 仅本设备可用（`AfterFirstUnlockThisDeviceOnly`），不上 iCloud 同步。
final class StepfunKeychainStore: StepfunTokenStoring {
    private let service: String
    private let account: String

    init(service: String = StepfunKeychain.service, account: String = StepfunKeychain.account) {
        self.service = service
        self.account = account
    }

    func readToken() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { return nil }
            throw StepfunKeychainError.keychainUnavailable(status)
        }
        guard let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            throw StepfunKeychainError.keychainUnavailable(errSecDecode)
        }
        return token
    }

    func writeToken(_ token: String) throws {
        let existsStatus = SecItemCopyMatching(baseQuery as CFDictionary, nil)
        switch existsStatus {
        case errSecSuccess:
            let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
            let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else {
                throw StepfunKeychainError.keychainUnavailable(status)
            }
        case errSecItemNotFound:
            var attributes = baseQuery
            attributes[kSecValueData as String] = Data(token.utf8)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw StepfunKeychainError.keychainUnavailable(status)
            }
        default:
            throw StepfunKeychainError.keychainUnavailable(existsStatus)
        }
    }

    func deleteToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StepfunKeychainError.keychainUnavailable(status)
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
