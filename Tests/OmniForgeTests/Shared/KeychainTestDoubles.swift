import Foundation
import Security
@testable import OmniForge

/// 内存假钥匙串：按 `service|account` 存取，不触碰系统 Keychain。
///
/// 自有凭据 store 的单元测试统一注入此假件。真实 `SecItem*` 调用会触发系统授权弹窗，
/// 且测试进程签名随构建变化，授权无法稳定记忆，故测试不访问真实钥匙串。
final class InMemoryKeychain {
    /// 已存条目（key = service|account）。
    private(set) var items: [String: Data] = [:]
    /// 非 nil 时 `copyMatching` 直接返回该状态（模拟钥匙串不可用 / 读取被拒）。
    var copyStatusOverride: OSStatus?
    /// `update` 的返回状态（默认成功）。
    var updateStatus: OSStatus = errSecSuccess
    /// `add` 的返回状态（默认成功）。
    var addStatus: OSStatus = errSecSuccess
    /// 非 nil 时 `delete` 直接返回该状态；nil 按「条目是否存在」返回 success/notFound。
    var deleteStatusOverride: OSStatus?
    /// `copyMatching` 调用次数（断言探测/读取次数）。
    private(set) var copyMatchingCallCount = 0

    var operations: KeychainItemOperations {
        KeychainItemOperations(
            copyMatching: { [self] query in
                copyMatchingCallCount += 1
                if let copyStatusOverride {
                    return (copyStatusOverride, nil)
                }
                guard let data = items[key(query)] else {
                    return (errSecItemNotFound, nil)
                }
                let wantsData = (query[kSecReturnData as String] as? Bool) == true
                return (errSecSuccess, wantsData ? data : nil)
            },
            update: { [self] query, attributes in
                guard items[key(query)] != nil else { return errSecItemNotFound }
                if let data = attributes[kSecValueData as String] as? Data {
                    items[key(query)] = data
                }
                return updateStatus
            },
            add: { [self] attributes in
                guard addStatus == errSecSuccess else { return addStatus }
                if let data = attributes[kSecValueData as String] as? Data {
                    items[key(attributes)] = data
                }
                return addStatus
            },
            delete: { [self] query in
                if let deleteStatusOverride { return deleteStatusOverride }
                return items.removeValue(forKey: key(query)) != nil ? errSecSuccess : errSecItemNotFound
            }
        )
    }

    private func key(_ query: [String: Any]) -> String {
        let service = query[kSecAttrService as String] as? String ?? ""
        let account = query[kSecAttrAccount as String] as? String ?? ""
        return "\(service)|\(account)"
    }
}
