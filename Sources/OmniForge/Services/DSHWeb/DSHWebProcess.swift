import AppKit
import Foundation

// MARK: - 进程控制协议

/// 进程句柄：manager 通过它发信号并观察退出。
protocol DSHWebProcessControlling: AnyObject {
    var isRunning: Bool { get }
    var pid: Int32 { get }
    /// SIGTERM 优雅终止。
    func terminate()
    /// SIGTERM 超时后的 SIGKILL 兜底。
    func forceTerminate()
    /// 进程退出回调（任意线程触发）。设置时若进程已退出则立即触发一次。
    var onExit: (() -> Void)? { get set }
}

/// 启动器：生产实现基于 Process + zsh -lc；测试注入 fake。
protocol DSHWebProcessLaunching {
    func launch(
        command: String,
        workingDirectory: URL,
        stdout: FileHandle?,
        stderr: FileHandle?
    ) throws -> DSHWebProcessControlling
}

/// 用 NSWorkspace 打开 URL（生产实现）；测试注入 fake。
protocol BrowserOpening {
    func open(_ url: URL)
}

// MARK: - 生产实现

/// Process 包装：terminationHandler 转发 onExit；forceTerminate 经 Darwin kill。
final class ProcessBackedDSHWebProcess: DSHWebProcessControlling {
    private let process: Process
    private let lock = NSLock()
    private var storedOnExit: (() -> Void)?
    private var didExit = false

    init(process: Process) {
        self.process = process
        process.terminationHandler = { [weak self] _ in
            self?.handleTermination()
        }
    }

    var isRunning: Bool { process.isRunning }

    var pid: Int32 { process.processIdentifier }

    func terminate() {
        process.terminate()
    }

    func forceTerminate() {
        kill(process.processIdentifier, SIGKILL)
    }

    var onExit: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedOnExit
        }
        set {
            lock.lock()
            storedOnExit = newValue
            let alreadyExited = didExit
            lock.unlock()
            // 设置时进程已退出（terminationHandler 先于 setter 触发）→ 立即回调，避免丢失。
            if alreadyExited {
                newValue?()
            }
        }
    }

    private func handleTermination() {
        lock.lock()
        didExit = true
        let callback = storedOnExit
        lock.unlock()
        callback?()
    }
}

/// `/bin/zsh -lc "exec dsh web"` 启动器：login shell 环境含 nvm 的 PATH；
/// `exec` 让 shell 被 dsh 替换，terminate() 直接作用于 dsh 本体。
final class ZshDSHWebProcessLauncher: DSHWebProcessLaunching {
    func launch(
        command: String,
        workingDirectory: URL,
        stdout: FileHandle?,
        stderr: FileHandle?
    ) throws -> DSHWebProcessControlling {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = workingDirectory
        if let stdout {
            process.standardOutput = stdout
        }
        if let stderr {
            process.standardError = stderr
        }
        try process.run()
        return ProcessBackedDSHWebProcess(process: process)
    }
}

final class WorkspaceBrowserOpener: BrowserOpening {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
