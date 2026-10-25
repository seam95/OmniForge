import Foundation
import Security

// MARK: - Security 调用注入点

/// Security 调用注入点：生产使用真实 `SecItem*`；测试注入闭包模拟，不触碰真实用户钥匙串。
///
/// 背景：真实 SecItem 读写会访问系统钥匙串。在单元测试里调用会弹出授权提示，
/// 且测试进程签名每次构建都不同，授权无法稳定记忆。所有自有凭据存储统一走此注入点，
/// 测试只验证 add/update/delete 分支逻辑，不产生系统副作用。
struct KeychainItemOperations {
    /// 查询条目；返回状态与带 `kSecReturnData` 时的数据。
    var copyMatching: ([String: Any]) -> (status: OSStatus, data: Data?)
    /// 更新已存在条目。
    var update: (_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    /// 新增条目。
    var add: (_ attributes: [String: Any]) -> OSStatus
    /// 删除条目。
    var delete: (_ query: [String: Any]) -> OSStatus

    /// 生产实现：直接调用 Security 框架。
    static let live = KeychainItemOperations(
        copyMatching: { query in
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item as? Data)
        },
        update: { query, attributes in
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        },
        add: { attributes in
            SecItemAdd(attributes as CFDictionary, nil)
        },
        delete: { query in
            SecItemDelete(query as CFDictionary)
        }
    )
}
