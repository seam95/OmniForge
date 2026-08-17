import Foundation
@testable import OmniForge

// MARK: - 进程句柄

/// 可控的进程句柄：terminate / forceTerminate 计数、手动模拟退出。
/// onExit 语义与生产实现一致：设置时若进程已退出则立即触发一次。
final class FakeProcessHandle: DSHWebProcessControlling {
    let pid: Int32
    private(set) var terminateCount = 0
    private(set) var forceTerminateCount = 0
    private var storedOnExit: (() -> Void)?
    private var didExit = false

    init(pid: Int32 = 4242) {
        self.pid = pid
    }

    var isRunning: Bool = true

    func terminate() {
        terminateCount += 1
    }

    func forceTerminate() {
        forceTerminateCount += 1
    }

    var onExit: (() -> Void)? {
        get { storedOnExit }
        set {
            storedOnExit = newValue
            if didExit { newValue?() }
        }
    }

    /// 模拟进程退出：置 isRunning = false 并触发 onExit。
    func simulateExit() {
        guard !didExit else { return }
        didExit = true
        isRunning = false
        storedOnExit?()
    }
}

// MARK: - 启动器

/// 可控启动器：可抛错；句柄按 launch 次序从 handles 取，不足时自动新建。
final class FakeProcessLauncher: DSHWebProcessLaunching {
    struct LaunchError: Error {}

    /// 非 nil 时每次 launch 都抛该错误。
    var error: Error?
    /// 按 launch 次序返回的句柄；不足时自动新建并追加。
    var handles: [FakeProcessHandle] = []
    private(set) var launchCount = 0
    private(set) var lastCommand: String?

    func launch(
        command: String,
        workingDirectory: URL,
        stdout: FileHandle?,
        stderr: FileHandle?
    ) throws -> DSHWebProcessControlling {
        launchCount += 1
        lastCommand = command
        if let error { throw error }
        if launchCount - 1 < handles.count {
            return handles[launchCount - 1]
        }
        let handle = FakeProcessHandle()
        handles.append(handle)
        return handle
    }
}

// MARK: - 端口探测

/// 按序返回结果；队列耗尽后重复最后一个值，保证轮询消费次数不确定时行为稳定。
final class FakeDSHWebPortProbe: DSHWebPortProbing {
    var results: [Bool] = [false]
    private(set) var callCount = 0

    func isPortOpen(_ port: UInt16) -> Bool {
        callCount += 1
        return results[min(callCount - 1, results.count - 1)]
    }

    /// 重置调用计数：测试重设 results 后从第一个元素重新消费。
    func reset() {
        callCount = 0
    }
}

// MARK: - 浏览器

final class FakeBrowserOpener: BrowserOpening {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) {
        openedURLs.append(url)
    }
}
