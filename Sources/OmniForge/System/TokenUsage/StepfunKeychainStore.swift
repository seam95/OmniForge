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
    private let tokenStore: KeychainItemStore<String>
    private let credentialsStore: KeychainItemStore<StepfunCredentials>

    init(
        service: String = StepfunKeychain.service,
        operations: KeychainItemOperations = .live
    ) {
        // 两个条目共享同一 service，仅 account 不同；字符串值语义一致。
        let makeStringStore: (String) -> KeychainItemStore<String> = { account in
            KeychainItemStore(
                service: service,
                account: account,
                operations: operations,
                // 数据存在但缺失/为空/不可解码：按不可读处理，不静默当成「未配置」。
                decode: { data in
                    guard let data,
                          let value = String(data: data, encoding: .utf8),
                          !value.isEmpty else {
                        throw StepfunKeychainError.keychainUnavailable(errSecDecode)
                    }
                    return value
                },
                encode: { Data($0.utf8) },
                failure: { StepfunKeychainError.keychainUnavailable($0) }
            )
        }
        tokenStore = makeStringStore(StepfunKeychain.tokenAccount)
        credentialsStore = KeychainItemStore(
            service: service,
            account: StepfunKeychain.credentialsAccount,
            operations: operations,
            // 值缺失/为空/不可解码 → 抛 errSecDecode；JSON 结构不符 → nil（按未配置处理）。
            decode: { data in
                guard let data,
                      let json = String(data: data, encoding: .utf8),
                      !json.isEmpty else {
                    throw StepfunKeychainError.keychainUnavailable(errSecDecode)
                }
                return try? JSONDecoder().decode(StepfunCredentials.self, from: data)
            },
            // 凭证以 JSON 字符串的 UTF-8 字节落盘；编码失败 → errSecParam。
            encode: { credentials in
                guard let data = try? JSONEncoder().encode(credentials),
                      let json = String(data: data, encoding: .utf8),
                      let bytes = json.data(using: .utf8) else {
                    throw StepfunKeychainError.keychainUnavailable(errSecParam)
                }
                return bytes
            },
            failure: { StepfunKeychainError.keychainUnavailable($0) }
        )
    }

    // MARK: - Token

    func hasToken() -> Bool {
        tokenStore.hasItem()
    }

    func readToken() throws -> String? {
        try tokenStore.read()
    }

    func writeToken(_ token: String) throws {
        try tokenStore.write(token)
    }

    func deleteToken() throws {
        try tokenStore.delete()
    }

    // MARK: - 凭证

    func hasCredentials() -> Bool {
        credentialsStore.hasItem()
    }

    func readCredentials() throws -> StepfunCredentials? {
        try credentialsStore.read()
    }

    func writeCredentials(_ credentials: StepfunCredentials) throws {
        try credentialsStore.write(credentials)
    }

    func deleteCredentials() throws {
        try credentialsStore.delete()
    }
}
