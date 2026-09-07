import Foundation
import OmniForgeSMC

/// 特权风扇 Helper 的 XPC 客户端 — 连接缓存复用，失效后按需重建。
/// XPC 传输层不做单测（真机验收），版本比对等纯逻辑见 FanHelperInstaller。
final class FanHelperClient {
    private let lock = NSRecursiveLock()
    private var connection: NSXPCConnection?

    /// 取命令代理（懒建连接）；连接无效返回 nil
    private func proxy() -> FanHelperProtocol? {
        lock.lock()
        defer { lock.unlock() }

        if let conn = connection {
            return proxy(for: conn)
        }
        let conn = NSXPCConnection(machServiceName: kFanHelperMachServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        // 递归锁：invalidation 回调可能在持锁期间内联触发
        conn.invalidationHandler = { [weak self] in
            self?.dropConnection(conn)
        }
        conn.resume()
        connection = conn
        return proxy(for: conn)
    }

    private func proxy(for conn: NSXPCConnection) -> FanHelperProtocol? {
        conn.remoteObjectProxyWithErrorHandler { _ in
            // 错误经各命令的 reply 闭包语义透传：Bool false / nil
        } as? FanHelperProtocol
    }

    /// 仅当 conn 仍是当前连接时清除 — 被替换后的迟到 invalidation 不得拆掉新连接
    private func dropConnection(_ conn: NSXPCConnection) {
        lock.lock()
        defer { lock.unlock() }
        if connection === conn {
            connection = nil
        }
    }

    func setFanSpeed(index: Int, rpm: Int, completion: @escaping (Bool, String?) -> Void) {
        guard let helper = proxy() else {
            completion(false, "helper unreachable")
            return
        }
        helper.setFanSpeed(fanIndex: index, rpm: rpm, reply: completion)
    }

    func setFanAuto(index: Int, completion: @escaping (Bool, String?) -> Void) {
        guard let helper = proxy() else {
            completion(false, "helper unreachable")
            return
        }
        helper.setFanMode(fanIndex: index, isAuto: true, reply: completion)
    }

    func resetAllFans(completion: @escaping (Bool, String?) -> Void) {
        guard let helper = proxy() else {
            completion(false, "helper unreachable")
            return
        }
        helper.resetAllFans(reply: completion)
    }

    /// 读取已安装 Helper 版本；连不上、连接中断或 3s 内无响应均回调 nil
    /// （无超时会让版本协商永久悬挂，设置页表现为转圈不停）
    func fetchVersion(completion: @escaping (String?) -> Void) {
        guard let helper = proxy() else {
            completion(nil)
            return
        }
        var replied = false
        let finish: (String?) -> Void = { version in
            guard !replied else { return }
            replied = true
            completion(version)
        }
        helper.getVersion { version in
            finish(version)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
            finish(nil)
        }
    }

    func invalidate() {
        lock.lock()
        let conn = connection
        connection = nil
        lock.unlock()
        conn?.invalidate()
    }
}
