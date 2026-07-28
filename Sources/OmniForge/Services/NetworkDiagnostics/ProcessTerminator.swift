import Darwin
import Foundation

// MARK: - Types

enum TerminationSignal: Equatable {
    case term
    case kill

    var posixValue: Int32 {
        switch self {
        case .term: return SIGTERM
        case .kill: return SIGKILL
        }
    }
}

enum TerminationOutcome: Equatable {
    /// `kill` 返回 0：信号已发出（不验证进程是否已退出）。
    case signalSent(TerminationSignal)
}

enum TerminationError: Error, Equatable {
    case blacklisted
    case invalidPID
    case notFound
    case permissionDenied
    case failed(errno: Int32)
}

// MARK: - Protocol

protocol ProcessTerminating {
    /// 是否允许结束（非法 PID / 自身 / 黑名单 → false）。
    func canTerminate(pid: pid_t, name: String) -> Bool
    /// 发送 SIGTERM 或 SIGKILL；成功定义为 kill 返回 0。
    func terminate(
        pid: pid_t,
        name: String,
        signal: TerminationSignal
    ) -> Result<TerminationOutcome, TerminationError>
}

// MARK: - Production terminator

final class ProcessTerminator: ProcessTerminating {
    /// SIGTERM 后刷新前的观察窗口（秒），避免过早判定失败。
    static let postTermRefreshDelay: TimeInterval = 1.5

    /// 系统/自身关键进程名（小写匹配）。
    static let blacklistedNames: Set<String> = [
        "kernel_task",
        "windowserver",
        "launchd",
        "loginwindow",
        "finder",
        "dock",
        "systemuiserver",
        "coreservicesd",
        "cfprefsd",
        "distnoted",
        "syslogd",
        "userseventagent",
        "universalaccessd",
    ]

    private let ownPID: pid_t
    private let killFn: (pid_t, Int32) -> Int32
    private let errnoFn: () -> Int32
    private let blacklist: Set<String>
    private let selfNames: Set<String>

    init(
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        killFn: @escaping (pid_t, Int32) -> Int32 = { kill($0, $1) },
        errnoFn: @escaping () -> Int32 = { errno },
        blacklist: Set<String> = ProcessTerminator.blacklistedNames,
        selfNames: Set<String> = ProcessTerminator.defaultSelfNames()
    ) {
        self.ownPID = ownPID
        self.killFn = killFn
        self.errnoFn = errnoFn
        self.blacklist = blacklist
        self.selfNames = selfNames
    }

    func canTerminate(pid: pid_t, name: String) -> Bool {
        guard pid > 0, pid != ownPID else { return false }
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return false }
        if blacklist.contains(lower) { return false }
        if selfNames.contains(lower) { return false }
        return true
    }

    func terminate(
        pid: pid_t,
        name: String,
        signal: TerminationSignal = .term
    ) -> Result<TerminationOutcome, TerminationError> {
        guard pid > 0 else { return .failure(.invalidPID) }
        // Match canTerminate(): trim + lower before blacklist / self-name checks.
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard canTerminate(pid: pid, name: name) else {
            if pid == ownPID || selfNames.contains(normalized) || blacklist.contains(normalized) {
                return .failure(.blacklisted)
            }
            return .failure(.invalidPID)
        }

        let rc = killFn(pid, signal.posixValue)
        if rc == 0 {
            return .success(.signalSent(signal))
        }
        let err = errnoFn()
        switch err {
        case ESRCH:
            return .failure(.notFound)
        case EPERM:
            return .failure(.permissionDenied)
        default:
            return .failure(.failed(errno: err))
        }
    }

    // MARK: Copyable shell commands（无应用内提权）

    static func sudoKillCommand(pid: pid_t) -> String {
        "sudo kill \(pid)"
    }

    static func sudoKill9Command(pid: pid_t) -> String {
        "sudo kill -9 \(pid)"
    }

    /// SIGTERM 失败后是否应提示升级 SIGKILL。
    static func shouldOfferForceKill(after error: TerminationError) -> Bool {
        switch error {
        case .permissionDenied, .failed, .notFound:
            return true
        case .blacklisted, .invalidPID:
            return false
        }
    }

    /// SIGKILL 仍失败时，是否应提供可复制的 sudo 命令。
    static func shouldOfferSudoKill9(after error: TerminationError) -> Bool {
        switch error {
        case .permissionDenied, .failed:
            return true
        case .notFound, .blacklisted, .invalidPID:
            return false
        }
    }

    static func defaultSelfNames() -> Set<String> {
        // 同时识别新名 omniforge 与历史名 inputlock，避免开发期残留的旧进程被误杀
        var names: Set<String> = ["omniforge", "inputlock"]
        if let display = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String {
            let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                names.insert(trimmed.lowercased())
            }
        }
        if let display = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
            let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                names.insert(trimmed.lowercased())
            }
        }
        return names
    }
}
