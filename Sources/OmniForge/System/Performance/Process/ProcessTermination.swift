import AppKit
import Foundation

/// 占用排行中"点图标 → 终止进程"的安全控制。
///
/// 终止是不可逆的高危操作（可能丢失目标 app 未保存的数据），因此对系统关键进程做黑名单保护，
/// 并统一走优雅退出（`terminate`）而非暴力强杀，给目标 app 正常收尾的机会。
enum ProcessTermination {
    /// 系统关键进程名（小写匹配）：终止它们会导致崩溃、注销或登录会话丢失，一律禁止。
    private static let blockedNames: Set<String> = [
        "kernel_task",
        "launchd",
        "loginwindow",
        "windowserver",
        "finder",
        "systemuiserver",
        "dock",
        "coreservicesd"
    ]

    /// 判断进程是否可被本功能终止。
    ///
    /// 不可终止的情况：pid 非法、自身、命中关键进程名黑名单。
    /// - Parameters:
    ///   - pid: 目标进程 pid。
    ///   - name: 目标进程显示名（与黑名单做小写匹配）。
    ///   - ownPID: 本应用自身 pid（用于排除误杀自己）。
    /// - Returns: 允许终止返回 `true`。
    static func canTerminate(pid: pid_t, name: String, ownPID: pid_t) -> Bool {
        guard pid > 0, pid != ownPID else { return false }
        return !blockedNames.contains(name.lowercased())
    }

    /// 优雅终止进程：优先请求 GUI app 正常退出，失败时回退 `kill`（TERM 信号）。
    ///
    /// 仅当 `canTerminate` 通过时才应调用。终止在后台线程执行，避免阻塞 UI。
    /// - Parameter pid: 目标进程 pid。
    /// - Returns: 是否成功发出了终止请求（不代表目标已完成退出）。
    @discardableResult
    static func terminate(pid: pid_t) -> Bool {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.terminate()
            return true
        }
        // 非 GUI 进程（守护进程等）回退到 TERM 信号；调用方应已通过 canTerminate 过滤。
        return kill(pid, SIGTERM) == 0
    }
}
