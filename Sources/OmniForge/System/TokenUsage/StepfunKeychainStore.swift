import Foundation
import Security

// MARK: - 条目命名

/// StepFun Oasis-Token 的 Keychain 条目。
enum StepfunKeychain {
    static let service = "app.omniforge.stepfun"
    static let tokenAccount = "oasis-token"
    static let credentialsAccount = "credentials"
}

/// StepFun 账号密码凭证（用于 30 天设备段失效后自动重登）。
struct StepfunCredentials: Equatable, Codable {
    var username: String
    var password: String

    var isValid: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 协议边界

/// StepFun Oasis-Token 与凭证存取边界 — 读/写/删分离；write 为「add or update」幂等。
protocol StepfunTokenStoring: AnyObject {
    /// 只探测条目存在性，不读取密码（不触发钥匙串授权弹窗）。
    func hasToken() -> Bool
    func readToken() throws -> String?
    func writeToken(_ token: String) throws
    func deleteToken() throws
    /// 只探测条目存在性，不读取密码（不触发钥匙串授权弹窗）。
    func hasCredentials() -> Bool
    func readCredentials() throws -> StepfunCredentials?
    func writeCredentials(_ credentials: StepfunCredentials) throws
    func deleteCredentials() throws
}

enum StepfunKeychainError: Error, Equatable {
    case keychainUnavailable(OSStatus)
}

// MARK: - Keychain 实现

/// 用 Security 框架读写 StepFun 的 Oasis-Token 与账号密码凭证。
/// 仅本设备可用（`AfterFirstUnlockThisDeviceOnly`），不上 iCloud 同步。
final class StepfunKeychainStore: StepfunTokenStoring {
    private let service: String
    private let operations: KeychainItemOperations

    init(
        service: String = StepfunKeychain.service,
        operations: KeychainItemOperations = .live
    ) {
        self.service = service
        self.operations = operations
    }

    // MARK: - Token

    func hasToken() -> Bool {
        hasValue(account: StepfunKeychain.tokenAccount)
    }

    func readToken() throws -> String? {
        try readString(account: StepfunKeychain.tokenAccount)
    }

    func writeToken(_ token: String) throws {
        try writeString(token, account: StepfunKeychain.tokenAccount)
    }

    func deleteToken() throws {
        try delete(account: StepfunKeychain.tokenAccount)
    }

    // MARK: - 凭证

    func hasCredentials() -> Bool {
        hasValue(account: StepfunKeychain.credentialsAccount)
    }

    func readCredentials() throws -> StepfunCredentials? {
        guard let json = try readString(account: StepfunKeychain.credentialsAccount),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(StepfunCredentials.self, from: data) else {
            return nil
        }
        return decoded
    }

    func writeCredentials(_ credentials: StepfunCredentials) throws {
        guard let data = try? JSONEncoder().encode(credentials),
              let json = String(data: data, encoding: .utf8) else {
            throw StepfunKeychainError.keychainUnavailable(errSecParam)
        }
        try writeString(json, account: StepfunKeychain.credentialsAccount)
    }

    func deleteCredentials() throws {
        try delete(account: StepfunKeychain.credentialsAccount)
    }

    // MARK: - 私有通用读写

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func readString(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let result = operations.copyMatching(query)
        guard result.status == errSecSuccess else {
            if result.status == errSecItemNotFound { return nil }
            throw StepfunKeychainError.keychainUnavailable(result.status)
        }
        guard let data = result.data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw StepfunKeychainError.keychainUnavailable(errSecDecode)
        }
        return value
    }

    private func writeString(_ value: String, account: String) throws {
        let query = baseQuery(account: account)
        let existsStatus = operations.copyMatching(query).status
        switch existsStatus {
        case errSecSuccess:
            let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
            let status = operations.update(query, attributes)
            guard status == errSecSuccess else {
                throw StepfunKeychainError.keychainUnavailable(status)
            }
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = Data(value.utf8)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = operations.add(attributes)
            guard status == errSecSuccess else {
                throw StepfunKeychainError.keychainUnavailable(status)
            }
        default:
            throw StepfunKeychainError.keychainUnavailable(existsStatus)
        }
    }

    /// 存在性探测：不带 `kSecReturnData`，只判断条目是否存在，不读密码。
    private func hasValue(account: String) -> Bool {
        operations.copyMatching(baseQuery(account: account)).status == errSecSuccess
    }

    private func delete(account: String) throws {
        let status = operations.delete(baseQuery(account: account))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StepfunKeychainError.keychainUnavailable(status)
        }
    }
}
