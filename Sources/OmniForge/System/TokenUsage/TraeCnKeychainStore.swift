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
    private let store: KeychainItemStore<String>

    init(
        service: String = TraeCnKeychain.service,
        account: String = TraeCnKeychain.account,
        operations: KeychainItemOperations = .live
    ) {
        store = KeychainItemStore(
            service: service,
            account: account,
            operations: operations,
            // 数据存在但缺失/为空/不可解码：按不可读处理，不静默当成「未配置」。
            decode: { data in
                guard let data,
                      let jwt = String(data: data, encoding: .utf8),
                      !jwt.isEmpty else {
                    throw TraeCnKeychainError.keychainUnavailable(errSecDecode)
                }
                return jwt
            },
            encode: { Data($0.utf8) },
            failure: { TraeCnKeychainError.keychainUnavailable($0) }
        )
    }

    /// 存在性探测：不带 `kSecReturnData`，只判断条目是否存在，不读密码。
    func hasJWT() -> Bool {
        store.hasItem()
    }

    func readJWT() throws -> String? {
        try store.read()
    }

    func writeJWT(_ jwt: String) throws {
        try store.write(jwt)
    }

    func deleteJWT() throws {
        try store.delete()
    }
}