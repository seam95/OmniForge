import Foundation
import OmniForgeSMC

/// 特权风扇 Helper 的 XPC 客户端 — 连接缓存复用，失效后按需重建。
/// XPC 传输层不做单测（真机验收），版本比对等纯逻辑见 FanHelperInstaller。
///
/// 回执可靠性契约（审查 R08）：每条命令的完成只发生一次；传输错误
/// （连接断开 / Helper 死亡）与无回复超时都归一为失败回调，
/// 不会让调用方永久悬挂，晚到的回执因守卫已完成而被丢弃。
final class FanHelperClient {
    private let lock = NSRecursiveLock()
    private var connection: NSXPCConnection?
    /// 在途命令守卫：连接级错误时统一失败补偿。
    private var pendingGuards: Set<ReplyGuard> = []

    /// 单命令回执守卫：正常回复、传输失败、超时三个来源竞态时只完成一次；
    /// 完成后经 onFinished 从在途集合移除。
    final class ReplyGuard: Hashable {
        static func == (lhs: ReplyGuard, rhs: ReplyGuard) -> Bool { lhs === rhs }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

        private let completion: (Bool, String?) -> Void
        private let stateLock = NSLock()
        private var finished = false
        private var timeoutWork: DispatchWorkItem?
        var onFinished: ((ReplyGuard) -> Void)?

        init(completion: @escaping (Bool, String?) -> Void) {
            self.completion = completion
        }

        func finish(_ ok: Bool, _ error: String?) {
            stateLock.lock()
            guard !finished else {
                stateLock.unlock()
                return
            }
            finished = true
            let work = timeoutWork
            timeoutWork = nil
            stateLock.unlock()
            work?.cancel()
            completion(ok, error)
            onFinished?(self)
        }

        /// 无回复兜底超时：晚到的成功/失败回执因已 finished 被丢弃。
        func armTimeout(seconds: TimeInterval, reason: String) {
            let work = DispatchWorkItem { [weak self] in
                self?.finish(false, reason)
            }
            stateLock.lock()
            guard !finished else {
                stateLock.unlock()
                return
            }
            timeoutWork = work
            stateLock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

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
            self?.handleConnectionInvalidated(conn)
        }
        conn.resume()
        connection = conn
        return proxy(for: conn)
    }

    private func proxy(for conn: NSXPCConnection) -> FanHelperProtocol? {
        conn.remoteObjectProxyWithErrorHandler { [weak self] _ in
            // 连接级错误：统一补偿所有在途命令（对应 reply 不会再到达）
            self?.failAllPending("helper connection lost")
        } as? FanHelperProtocol
    }

    /// 仅当 conn 仍是当前连接时清除 — 被替换后的迟到 invalidation 不得拆掉新连接
    private func handleConnectionInvalidated(_ conn: NSXPCConnection) {
        lock.lock()
        let isCurrent = connection === conn
        if isCurrent {
            connection = nil
        }
        lock.unlock()
        if isCurrent {
            failAllPending("helper connection invalidated")
        }
    }

    /// 连接级失败补偿：所有在途命令立即以失败完成（守卫幂等保证只完成一次）。
    private func failAllPending(_ reason: String) {
        lock.lock()
        let guards = Array(pendingGuards)
        pendingGuards.removeAll()
        lock.unlock()
        for box in guards {
            box.finish(false, reason)
        }
    }

    /// 命令统一包装：登记守卫 + 超时兜底 + 正常路径完成。
    private func performCommand(
        timeout: TimeInterval = 5,
        timeoutReason: String = "helper reply timeout",
        invoke: (FanHelperProtocol, @escaping (Bool, String?) -> Void) -> Void,
        completion: @escaping (Bool, String?) -> Void
    ) {
        guard let helper = proxy() else {
            completion(false, "helper unreachable")
            return
        }
        let replyGuard = ReplyGuard(completion: completion)
        replyGuard.onFinished = { [weak self] box in
            guard let self else { return }
            self.lock.lock()
            self.pendingGuards.remove(box)
            self.lock.unlock()
        }
        lock.lock()
        pendingGuards.insert(replyGuard)
        lock.unlock()
        replyGuard.armTimeout(seconds: timeout, reason: timeoutReason)
        invoke(helper) { ok, error in
            replyGuard.finish(ok, error)
        }
    }

    func setFanSpeed(index: Int, rpm: Int, completion: @escaping (Bool, String?) -> Void) {
        performCommand { helper, reply in
            helper.setFanSpeed(fanIndex: index, rpm: rpm, reply: reply)
        } completion: { ok, error in
            completion(ok, error)
        }
    }

    func setFanAuto(index: Int, completion: @escaping (Bool, String?) -> Void) {
        performCommand { helper, reply in
            helper.setFanMode(fanIndex: index, isAuto: true, reply: reply)
        } completion: { ok, error in
            completion(ok, error)
        }
    }

    func resetAllFans(completion: @escaping (Bool, String?) -> Void) {
        performCommand(timeout: 8, timeoutReason: "helper reset timeout") { helper, reply in
            helper.resetAllFans(reply: reply)
        } completion: { ok, error in
            completion(ok, error)
        }
    }

    /// 读取已安装 Helper 版本；连不上、连接中断或 3s 内无响应均回调 nil
    /// （无超时会让版本协商永久悬挂，设置页表现为转圈不停）。
    /// 与命令共用连接级失败补偿与「只完成一次」语义。
    func fetchVersion(completion: @escaping (String?) -> Void) {
        guard let helper = proxy() else {
            completion(nil)
            return
        }
        var replied = false
        let stateLock = NSLock()
        let finish: (String?) -> Void = { version in
            stateLock.lock()
            guard !replied else {
                stateLock.unlock()
                return
            }
            replied = true
            stateLock.unlock()
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
