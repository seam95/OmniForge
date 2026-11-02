import Foundation
import Security

// MARK: - 泛型 Keychain 条目存储

/// 泛型 Keychain 条目存储：把「存在性探测 / 读数据 / add-or-update 写 / 幂等删」的
/// `kSec` 查询构造与分支逻辑收敛为唯一实现。
///
/// 各凭据 store 只注入 service/account、编解码闭包与错误包装，差异全在闭包里：
/// - `decode` 返回 nil = 「条目存在但值无效，按未配置处理」；抛错 = 「数据不可读，上抛」。
/// - `encode` 返回 nil = 「跳过写入（如编码失败静默放弃）」；抛错 = 「编码失败上抛」。
///
/// 条目统一为 `kSecClassGenericPassword`，仅本设备可用
/// （`AfterFirstUnlockThisDeviceOnly`），不上 iCloud 同步。
struct KeychainItemStore<Payload> {
    let service: String
    let account: String
    let operations: KeychainItemOperations
    let decode: (Data?) throws -> Payload?
    let encode: (Payload) throws -> Data?
    let failure: (OSStatus) -> Error

    /// 存在性探测：不带 `kSecReturnData`，只判断条目是否存在，不读密码（不触发钥匙串授权弹窗）。
    func hasItem() -> Bool {
        operations.copyMatching(baseQuery).status == errSecSuccess
    }

    /// 读取载荷；条目不存在 → nil。
    func read() throws -> Payload? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let result = operations.copyMatching(query)
        guard result.status == errSecSuccess else {
            // 条目不存在是「未配置」，不是读取失败。
            if result.status == errSecItemNotFound { return nil }
            throw failure(result.status)
        }
        return try decode(result.data)
    }

    /// 写入载荷（幂等：不存在则新增，存在则更新）。
    func write(_ payload: Payload) throws {
        guard let data = try encode(payload) else { return }
        // SecItemUpdate 的查询字典与 Delete 同构（class + service + account），不带 match limit。
        let existsStatus = operations.copyMatching(baseQuery).status
        switch existsStatus {
        case errSecSuccess:
            let attributes: [String: Any] = [kSecValueData as String: data]
            let status = operations.update(baseQuery, attributes)
            guard status == errSecSuccess else {
                throw failure(status)
            }
        case errSecItemNotFound:
            var attributes = baseQuery
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = operations.add(attributes)
            guard status == errSecSuccess else {
                throw failure(status)
            }
        default:
            throw failure(existsStatus)
        }
    }

    /// 删除条目（幂等：条目不存在视为成功）。
    func delete() throws {
        let status = operations.delete(baseQuery)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw failure(status)
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
