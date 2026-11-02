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
    private let store: KeychainItemStore<ArkCredentials>

    init(
        service: String = ArkKeychain.service,
        account: String = ArkKeychain.account,
        operations: KeychainItemOperations = .live
    ) {
        store = KeychainItemStore(
            service: service,
            account: account,
            operations: operations,
            // 数据缺失、解码失败或字段无效：一律按「未配置」处理，不上抛。
            decode: { data in
                data
                    .flatMap { try? JSONDecoder().decode(ArkCredentials.self, from: $0) }
                    .flatMap { $0.isValid ? $0 : nil }
            },
            // 编码失败：静默跳过写入。
            encode: { try? JSONEncoder().encode($0) },
            failure: { ArkKeychainError.keychainUnavailable($0) }
        )
    }

    func hasCredentials() -> Bool {
        store.hasItem()
    }

    func readCredentials() throws -> ArkCredentials? {
        try store.read()
    }

    func writeCredentials(_ credentials: ArkCredentials) throws {
        try store.write(credentials)
    }

    func deleteCredentials() throws {
        try store.delete()
    }
}
