import Combine
import Foundation

// MARK: - 状态

extension DSHWebManager {
    /// 服务生命周期状态；`failed` 携带可展示的失败原因。
    enum DSHWebState: Equatable {
        case stopped
        case starting
        case running
        case stopping
        case failed(String)
    }
}

/// DSH Web 服务管理器：以应用子进程方式启动 / 停止 / 重启 `dsh web`，
/// 轮询端口就绪后自动打开浏览器，内存环形缓冲保存运行日志（SPEC §2 / §4）。
/// 依赖全部协议化注入，测试用 fake 替换进程 / 探测 / 浏览器 / 时长。
@MainActor
final class DSHWebManager: ObservableObject {
    static let shared = DSHWebManager()

    // MARK: 常量

    static let port: UInt16 = 3080
    static let address = "http://127.0.0.1:3080"
    static let addressURL = URL(string: address)!
    static let launchCommand = "exec dsh web"
    static let logCapacity = 500

    // MARK: Published

    @Published private(set) var state: DSHWebState = .stopped
    @Published private(set) var logLines: [String] = []

    // MARK: Dependencies

    private let processLauncher: DSHWebProcessLaunching
    private let portProbe: DSHWebPortProbing
    private let browserOpener: BrowserOpening
    private let stringsProvider: () -> Strings
    private let pollInterval: Duration
    private let readyTimeout: Duration
    private let stopTimeout: Duration
    private let shutdownTimeout: Duration

    private var activeProcess: DSHWebProcessControlling?
    /// 持有管道防释放；readabilityHandler 读块后追加日志。
    private var outputPipes: [Pipe] = []
    private let eventFormatter = DSHWebManager.makeEventFormatter()

    init(
        processLauncher: DSHWebProcessLaunching = ZshDSHWebProcessLauncher(),
        portProbe: DSHWebPortProbing = NWConnectionPortProbe(),
        browserOpener: BrowserOpening = WorkspaceBrowserOpener(),
        stringsProvider: @escaping () -> Strings = { L10n(userDefaults: .standard).s },
        pollInterval: Duration = .milliseconds(500),
        readyTimeout: Duration = .seconds(15),
        stopTimeout: Duration = .seconds(5),
        shutdownTimeout: Duration = .seconds(3)
    ) {
        self.processLauncher = processLauncher
        self.portProbe = portProbe
        self.browserOpener = browserOpener
        self.stringsProvider = stringsProvider
        self.pollInterval = pollInterval
        self.readyTimeout = readyTimeout
        self.stopTimeout = stopTimeout
        self.shutdownTimeout = shutdownTimeout
    }

    // MARK: - 启动

    /// 启动流程：端口占用检查 → 拉起子进程 → 轮询就绪 → running + 打开浏览器。
    /// 仅在 stopped / failed 下生效（幂等）。
    func start() async {
        guard state == .stopped || isFailed else { return }

        // 前置检查：端口已被占用时不启动进程，直接失败。
        if portProbe.isPortOpen(Self.port) {
            let reason = stringsProvider().dshWebPortOccupied
            appendEvent(reason)
            state = .failed(reason)
            return
        }

        appendEvent("启动 dsh web")
        state = .starting

        let outPipe = makeOutputPipe()
        let errPipe = makeOutputPipe()
        let process: DSHWebProcessControlling
        do {
            process = try processLauncher.launch(
                command: Self.launchCommand,
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                stdout: outPipe.fileHandleForReading,
                stderr: errPipe.fileHandleForReading
            )
        } catch {
            let reason = stringsProvider().dshWebLaunchFailed
            appendEvent(reason)
            state = .failed(reason)
            return
        }
        activeProcess = process

        // 轮询端口就绪；超时或进程提前退出视为失败（并终止残留进程）。
        let deadline = Date().addingTimeInterval(seconds(readyTimeout))
        while state == .starting {
            guard process.isRunning else {
                await terminateProcess(process, timeout: stopTimeout)
                let reason = stringsProvider().dshWebStartTimeout
                appendEvent("进程提前退出，服务未就绪")
                state = .failed(reason)
                return
            }
            if portProbe.isPortOpen(Self.port) {
                appendEvent("服务就绪 :\(Self.port)")
                state = .running
                browserOpener.open(Self.addressURL)
                return
            }
            if Date() >= deadline {
                await terminateProcess(process, timeout: stopTimeout)
                let reason = stringsProvider().dshWebStartTimeout
                appendEvent("启动超时，服务未就绪")
                state = .failed(reason)
                return
            }
            try? await Task.sleep(for: pollInterval)
        }
    }

    // MARK: - 停止

    /// 停止流程：SIGTERM → 等待退出（stopTimeout）→ 未退出则 SIGKILL 兜底。
    /// 仅在 running 下生效。
    func stop() async {
        guard state == .running, let process = activeProcess else { return }
        state = .stopping
        await terminateProcess(process, timeout: stopTimeout)
        activeProcess = nil
        appendEvent("服务已停止")
        state = .stopped
    }

    /// 重启：任意状态归一为「先停后启」。
    func restart() async {
        if state == .running {
            await stop()
        }
        await start()
    }

    /// 仅在 running 下打开默认浏览器访问服务地址。
    func openInBrowser() {
        guard state == .running else { return }
        browserOpener.open(Self.addressURL)
    }

    /// 应用退出快速终止：SIGTERM + 最多 shutdownTimeout 等待；不 SIGKILL（系统即将回收）。
    /// 同步阻塞调用，供 prepareForApplicationTermination / teardownSync 使用。
    func shutdown() {
        guard let process = activeProcess,
              state == .running || state == .starting else { return }
        state = .stopping
        process.terminate()
        appendEvent("SIGTERM 已发送（应用退出）")
        let semaphore = DispatchSemaphore(value: 0)
        process.onExit = { semaphore.signal() }
        if !process.isRunning {
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + seconds(shutdownTimeout))
        activeProcess = nil
        appendEvent("服务已停止")
        state = .stopped
    }

    // MARK: - 日志

    func clearLog() {
        logLines.removeAll()
    }

    /// 写入一条带时间戳的管理事件行（internal，测试直接验证缓冲契约）。
    func appendEvent(_ text: String) {
        let line = "[\(eventFormatter.string(from: Date()))] \(text)"
        appendLine(line)
    }

    // MARK: - 进程控制

    /// 发 SIGTERM 并等待退出；timeout 内未退出则 SIGKILL 兜底。
    private func terminateProcess(_ process: DSHWebProcessControlling, timeout: Duration) async {
        process.terminate()
        appendEvent("SIGTERM 已发送")
        let exited = await waitForExit(of: process, timeout: timeout)
        if !exited {
            process.forceTerminate()
            appendEvent("SIGKILL 已发送")
        }
    }

    /// 等待进程退出回调（任意线程触发）；timeout 内未退出返回 false。
    private func waitForExit(of process: DSHWebProcessControlling, timeout: Duration) async -> Bool {
        guard process.isRunning else { return true }
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            func finish(_ value: Bool) {
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    return
                }
                finished = true
                lock.unlock()
                continuation.resume(returning: value)
            }
            process.onExit = { finish(true) }
            if !process.isRunning {
                finish(true)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds(timeout)) {
                finish(false)
            }
        }
    }

    // MARK: - 输出采集

    /// 创建子进程 stdout/stderr 管道：逐块读取，追加到日志缓冲（MainActor）。
    private func makeOutputPipe() -> Pipe {
        let pipe = Pipe()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                Task { @MainActor [weak self] in
                    self?.appendLog(text)
                }
            }
        }
        outputPipes.append(pipe)
        return pipe
    }

    /// 子进程原始输出原样追加（无时间戳）。
    private func appendLog(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            appendLine(String(line))
        }
    }

    /// 环形缓冲写入：超出 logCapacity 裁剪旧行。
    private func appendLine(_ line: String) {
        logLines.append(line)
        if logLines.count > Self.logCapacity {
            logLines.removeFirst(logLines.count - Self.logCapacity)
        }
    }

    // MARK: - Helpers

    /// 是否处于失败状态（携带可展示原因）。
    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private static func makeEventFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    private func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
