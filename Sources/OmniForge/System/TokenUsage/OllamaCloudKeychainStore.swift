import Foundation
import Security

// MARK: - 条目命名

/// 本应用自有 Keychain 条目命名（对齐 `DeepSeekKeychain` 的命名枚举风格）。
enum OllamaCloudKeychain {
    static let service = "app.omniforge.ollama-cloud"
    static let account = "api-key"
}

// MARK: - 协议边界

/// Ollama Cloud API Key 存取边界 — 读/写/删分离；write 为「add or update」幂等。
protocol OllamaCloudAPIKeyStoring: AnyObject {
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
enum OllamaCloudKeychainError: Error, Equatable {
    case keychainUnavailable(OSStatus)
}

// MARK: - Keychain 实现

/// 用 Security 框架读写本应用自有的 Ollama Cloud API Key 条目（ollama.com/settings/keys 创建）。
/// 仅本设备可用（`AfterFirstUnlockThisDeviceOnly`），不上 iCloud 同步。
final class OllamaCloudKeychainAPIKeyStore: OllamaCloudAPIKeyStoring {
    private let store: KeychainItemStore<String>

    init(
        service: String = OllamaCloudKeychain.service,
        account: String = OllamaCloudKeychain.account,
        operations: KeychainItemOperations = .live
    ) {
        store = KeychainItemStore(
            service: service,
            account: account,
            operations: operations,
            // 数据存在但缺失/为空/不可解码：按不可读处理，不静默当成「未配置」。
            decode: { data in
                guard let data,
                      let apiKey = String(data: data, encoding: .utf8),
                      !apiKey.isEmpty else {
                    throw OllamaCloudKeychainError.keychainUnavailable(errSecDecode)
                }
                return apiKey
            },
            encode: { Data($0.utf8) },
            failure: { OllamaCloudKeychainError.keychainUnavailable($0) }
        )
    }

    func hasAPIKey() -> Bool {
        store.hasItem()
    }

    func readAPIKey() throws -> String? {
        try store.read()
    }

    func writeAPIKey(_ apiKey: String) throws {
        try store.write(apiKey)
    }

    func deleteAPIKey() throws {
        try store.delete()
    }
}
