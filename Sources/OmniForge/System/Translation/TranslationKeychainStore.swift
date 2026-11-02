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

// MARK: - 实现

/// 翻译功能独立 API Key 存储：service=`app.omniforge.translation`，account=`api-key`。
///
/// 仅本设备可用（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`），不走 iCloud 同步。
/// 写入为 add or update 幂等；删除幂等；只有「条目不存在」返回 nil，其余读取失败向上抛错，
/// 避免把凭据读取失败误当成「匿名配置」。
final class TranslationKeychainStore: TranslationAPIKeyStoring {
    private let store: KeychainItemStore<String>

    init(
        service: String = TranslationKeychain.service,
        account: String = TranslationKeychain.account,
        operations: KeychainItemOperations = .live
    ) {
        store = KeychainItemStore(
            service: service,
            account: account,
            operations: operations,
            // 数据存在但为空或不可解码：按不可读处理，不静默当成匿名配置。
            decode: { data in
                guard let data,
                      let apiKey = String(data: data, encoding: .utf8),
                      !apiKey.isEmpty else {
                    throw TranslationKeychainError.keychainUnavailable(errSecDecode)
                }
                return apiKey
            },
            encode: { Data($0.utf8) },
            failure: { TranslationKeychainError.keychainUnavailable($0) }
        )
    }

    func readAPIKey() throws -> String? {
        try store.read()
    }

    func writeAPIKey(_ value: String) throws {
        try store.write(value)
    }

    func deleteAPIKey() throws {
        try store.delete()
    }
}
