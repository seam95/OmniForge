import Foundation
import Security

// MARK: - 条目命名

/// trae-cn JWT 的 Keychain 条目（SPEC R1：手动粘贴凭证，不做本地解密）。
enum TraeCnKeychain {
    static let service = "app.omniforge.traecn"
    static let account = "cloud-ide-jwt"
}

// MARK: - 协议边界

/// trae-cn JWT 存取边界 — 读/写/删分离；write 为「add or update」幂等。
protocol TraeCnJWTAccessing: AnyObject {
    /// 只探测条目存在性，不读取密码（不触发钥匙串授权弹窗）。
    func hasJWT() -> Bool
    func readJWT() throws -> String?
    func writeJWT(_ jwt: String) throws
    func deleteJWT() throws
}

enum TraeCnKeychainError: Error, Equatable {
    case keychainUnavailable(OSStatus)
}

// MARK: - Keychain 实现

/// 用 Security 框架读写 trae-cn 的 Cloud-IDE-JWT。
/// 仅本设备可用（`AfterFirstUnlockThisDeviceOnly`），不上 iCloud 同步。
final class TraeCnKeychainStore: TraeCnJWTAccessing {
    private let service: String
    private let account: String
    private let operations: KeychainItemOperations

    init(
        service: String = TraeCnKeychain.service,
        account: String = TraeCnKeychain.account,
        operations: KeychainItemOperations = .live
    ) {
        self.service = service
        self.account = account
        self.operations = operations
    }

    /// 存在性探测：不带 `kSecReturnData`，只判断条目是否存在，不读密码。
    func hasJWT() -> Bool {
        operations.copyMatching(baseQuery).status == errSecSuccess
    }

    func readJWT() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let result = operations.copyMatching(query)
        guard result.status == errSecSuccess else {
            if result.status == errSecItemNotFound { return nil }
            throw TraeCnKeychainError.keychainUnavailable(result.status)
        }
        guard let data = result.data,
              let jwt = String(data: data, encoding: .utf8),
              !jwt.isEmpty else {
            throw TraeCnKeychainError.keychainUnavailable(errSecDecode)
        }
        return jwt
    }

    func writeJWT(_ jwt: String) throws {
        let existsStatus = operations.copyMatching(baseQuery).status
        switch existsStatus {
        case errSecSuccess:
            let attributes: [String: Any] = [kSecValueData as String: Data(jwt.utf8)]
            let status = operations.update(baseQuery, attributes)
            guard status == errSecSuccess else {
                throw TraeCnKeychainError.keychainUnavailable(status)
            }
        case errSecItemNotFound:
            var attributes = baseQuery
            attributes[kSecValueData as String] = Data(jwt.utf8)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = operations.add(attributes)
            guard status == errSecSuccess else {
                throw TraeCnKeychainError.keychainUnavailable(status)
            }
        default:
            throw TraeCnKeychainError.keychainUnavailable(existsStatus)
        }
    }

    func deleteJWT() throws {
        let status = operations.delete(baseQuery)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TraeCnKeychainError.keychainUnavailable(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}