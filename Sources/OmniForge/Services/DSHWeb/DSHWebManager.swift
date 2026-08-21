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

    nonisolated static let defaultPort = 3080
    /// GUI 进程 PATH 不含 nvm；`zsh -c` 非交互不读 ~/.zshrc（nvm 配置所在），
    /// 因此显式 source 用户 shell 配置后再 exec，保证 dsh 可达且句柄即 dsh 本体。
    static let logCapacity = 500

    static func sanitizedPort(_ value: Int) -> Int {
        (1...Int(UInt16.max)).contains(value) ? value : defaultPort
    }

    static func address(for port: Int) -> String {
        "http://127.0.0.1:\(sanitizedPort(port))"
    }

    static func launchCommand(for port: Int) -> String {
        "source ~/.zprofile 2>/dev/null; source ~/.zshrc 2>/dev/null; exec dsh web --port \(sanitizedPort(port))"
    }

    // MARK: Published

    @Published private(set) var state: DSHWebState = .stopped
    @Published private(set) var logLines: [String] = []
    @Published private(set) var configuredPort: Int
    @Published private(set) var services: [DSHWebService] = []

    // MARK: Dependencies

    private let processLauncher: DSHWebProcessLaunching
    private let portProbe: DSHWebPortProbing
    private let browserOpener: BrowserOpening
    private let serviceDiscoverer: DSHWebServiceDiscovering
    private let serviceSignaler: DSHWebServiceSignaling
    private let userDefaults: UserDefaults
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
        serviceDiscoverer: DSHWebServiceDiscovering = SystemDSHWebServiceDiscoverer(),
        serviceSignaler: DSHWebServiceSignaling = DarwinDSHWebServiceSignaler(),
        userDefaults: UserDefaults = .standard,
        stringsProvider: @escaping () -> Strings = { L10n(userDefaults: .standard).s },
        pollInterval: Duration = .milliseconds(500),
        readyTimeout: Duration = .seconds(15),
        stopTimeout: Duration = .seconds(5),
        shutdownTimeout: Duration = .seconds(3)
    ) {
        self.processLauncher = processLauncher
        self.portProbe = portProbe
        self.browserOpener = browserOpener
        self.serviceDiscoverer = serviceDiscoverer
        self.serviceSignaler = serviceSignaler
        self.userDefaults = userDefaults
        let storedPort = userDefaults.object(forKey: UserDefaultsKeys.dshWebPort) == nil
            ? Self.defaultPort
            : userDefaults.integer(forKey: UserDefaultsKeys.dshWebPort)
        self.configuredPort = Self.sanitizedPort(storedPort)
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
        let port = UInt16(configuredPort)
        if portProbe.isPortOpen(port) {
            let reason = String(format: stringsProvider().dshWebPortOccupiedFormat, configuredPort)
            appendEvent(reason)
            state = .failed(reason)
            return
        }

        appendEvent("启动 dsh web :\(port)")
        state = .starting

        let outPipe = makeOutputPipe()
        let errPipe = makeOutputPipe()
        let process: DSHWebProcessControlling
        do {
            process = try processLauncher.launch(
                command: Self.launchCommand(for: configuredPort),
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
        process.onExit = { [weak self, weak process] in
            guard let process else { return }
            Task { @MainActor [weak self] in
                guard self?.activeProcess?.pid == process.pid else { return }
                self?.activeProcess = nil
                if self?.state == .running {
                    self?.appendEvent("dsh web 进程已退出")
                    self?.state = .stopped
                    await self?.refreshServices()
                }
            }
        }

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
            if portProbe.isPortOpen(port) {
                appendEvent("服务就绪 :\(port)")
                state = .running
                browserOpener.open(URL(string: Self.address(for: configuredPort))!)
                await refreshServices()
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
        await refreshServices()
    }

    /// 重启：任意状态归一为「先停后启」。
    func restart() async {
        if state == .running {
            await stop()
        }
        await start()
    }

    /// 仅在本应用启动的服务运行时打开默认浏览器访问其地址。
    func openInBrowser() {
        guard state == .running else { return }
        browserOpener.open(URL(string: Self.address(for: configuredPort))!)
    }

    func openInBrowser(_ service: DSHWebService) {
        guard let url = URL(string: service.address) else { return }
        browserOpener.open(url)
    }

    /// 提交用户端口设置。运行中的本应用子进程保持原端口，直到停止后再启动。
    func setConfiguredPort(_ port: Int) {
        guard state != .running, state != .starting, state != .stopping else { return }
        configuredPort = Self.sanitizedPort(port)
        userDefaults.set(configuredPort, forKey: UserDefaultsKeys.dshWebPort)
    }

    /// 刷新由任意入口启动的 DSH Web 实例。发现失败仅记日志，避免影响自有服务状态机。
    func refreshServices() async {
        do {
            services = try await serviceDiscoverer.discover()
        } catch {
            appendEvent("DSH Web 服务发现失败：\(error.localizedDescription)")
        }
    }

    func isOwnedByApplication(_ service: DSHWebService) -> Bool {
        activeProcess?.pid == service.pid
    }

    /// 停止指定实例。外部实例在发送信号前会重新发现并核验身份，避免 PID 复用误杀。
    func stop(service: DSHWebService) async {
        if isOwnedByApplication(service) {
            await stop()
            await refreshServices()
            return
        }

        guard let verified = await verifiedService(matching: service) else {
            appendEvent("目标 DSH Web 服务已变化，未发送停止信号")
            await refreshServices()
            return
        }
        guard serviceSignaler.terminate(pid: verified.pid) else {
            appendEvent("无法向 DSH Web 进程 \(verified.pid) 发送 SIGTERM")
            return
        }
        appendEvent("已向外部 DSH Web 进程 \(verified.pid) 发送 SIGTERM")

        if await waitForServiceExit(verified, timeout: stopTimeout) {
            await refreshServices()
            return
        }
        guard let stillRunning = await verifiedService(matching: verified) else {
            await refreshServices()
            return
        }
        if serviceSignaler.forceTerminate(pid: stillRunning.pid) {
            appendEvent("已向外部 DSH Web 进程 \(stillRunning.pid) 发送 SIGKILL")
        }
        await refreshServices()
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

    /// 再次发现且完整身份相同才允许对外部 PID 操作。
    private func verifiedService(matching target: DSHWebService) async -> DSHWebService? {
        guard let services = try? await serviceDiscoverer.discover() else { return nil }
        return services.first { DSHWebServiceSupport.isSameInstance($0, target) }
    }

    private func waitForServiceExit(_ service: DSHWebService, timeout: Duration) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds(timeout))
        while Date() < deadline {
            if await verifiedService(matching: service) == nil {
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }
        return await verifiedService(matching: service) == nil
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
