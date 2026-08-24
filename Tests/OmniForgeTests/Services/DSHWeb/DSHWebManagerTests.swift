import XCTest
@testable import OmniForge

/// DSHWebManager 状态机与进程生命周期契约（SPEC §6）。
/// 全部依赖注入 fake；轮询/等待时长注入极小值，测试不真实等待。
@MainActor
final class DSHWebManagerTests: XCTestCase {
    private var launcher: FakeProcessLauncher!
    private var probe: FakeDSHWebPortProbe!
    private var browser: FakeBrowserOpener!
    private var serviceDiscoverer: FakeDSHWebServiceDiscoverer!
    private var signaler: FakeDSHWebServiceSignaler!
    private var userDefaults: UserDefaults!
    private var manager: DSHWebManager!
    private let strings = Strings.zhHans

    override func setUp() {
        super.setUp()
        launcher = FakeProcessLauncher()
        probe = FakeDSHWebPortProbe()
        browser = FakeBrowserOpener()
        serviceDiscoverer = FakeDSHWebServiceDiscoverer()
        signaler = FakeDSHWebServiceSignaler()
        userDefaults = UserDefaults(suiteName: "DSHWebManagerTests.\(UUID().uuidString)")!
        manager = DSHWebManager(
            processLauncher: launcher,
            portProbe: probe,
            browserOpener: browser,
            serviceDiscoverer: serviceDiscoverer,
            serviceSignaler: signaler,
            userDefaults: userDefaults,
            stringsProvider: { [strings] in strings },
            pollInterval: .milliseconds(1),
            readyTimeout: .milliseconds(20),
            stopTimeout: .milliseconds(20),
            shutdownTimeout: .milliseconds(1)
        )
    }

    private func expectFailed(reason expected: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failed(let reason) = manager.state else {
            XCTFail("期望 failed，实际 \(manager.state)", file: file, line: line)
            return
        }
        XCTAssertEqual(reason, expected, file: file, line: line)
    }

    // MARK: - 启动

    /// probe 前置检查未占用、轮询第二次开放 → running + 自动打开浏览器。
    func test_start_success_transitionsToRunning_andOpensBrowser() async {
        probe.results = [false, false, true]

        await manager.start()

        XCTAssertEqual(manager.state, .running)
        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(launcher.lastCommand, DSHWebManager.launchCommand(for: 3080))
        XCTAssertTrue(launcher.lastCommand?.contains("exec dsh web --port 3080") == true)
        XCTAssertEqual(browser.openedURLs, [URL(string: "http://127.0.0.1:3080")!])
        XCTAssertTrue(manager.logLines.contains { $0.contains("服务就绪") })
    }

    /// 端口已被占用 → 立即 failed + 占用文案，且不启动进程。
    func test_start_portOccupied_failsWithoutLaunching() async {
        probe.results = [true]

        await manager.start()

        expectFailed(reason: strings.dshWebPortOccupied)
        XCTAssertEqual(launcher.launchCount, 0)
    }

    /// probe 恒关闭 → 轮询窗口耗尽 → failed + 超时文案；残留进程被终止。
    func test_start_readyTimeout_failsWithTimeoutMessage() async {
        probe.results = [false]

        await manager.start()

        expectFailed(reason: strings.dshWebStartTimeout)
        XCTAssertEqual(launcher.handles.first?.terminateCount, 1)
        XCTAssertEqual(launcher.handles.first?.forceTerminateCount, 1)
    }

    /// launch 抛错 → failed + 启动失败文案。
    func test_start_launchThrows_failsWithLaunchMessage() async {
        probe.results = [false]
        launcher.error = FakeProcessLauncher.LaunchError()

        await manager.start()

        expectFailed(reason: strings.dshWebLaunchFailed)
        XCTAssertEqual(launcher.launchCount, 1)
    }

    /// 进程启动后提前退出（如 dsh 启动即崩溃）→ failed + 超时文案。
    func test_start_processExitsEarly_fails() async {
        probe.results = [false]
        let handle = FakeProcessHandle()
        launcher.handles = [handle]

        let startTask = Task { await manager.start() }
        // 等 launch 完成、进入轮询后模拟进程退出。
        while launcher.launchCount == 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        handle.simulateExit()
        await startTask.value

        expectFailed(reason: strings.dshWebStartTimeout)
        XCTAssertEqual(handle.forceTerminateCount, 0)
    }

    /// running 下重复 start() 无副作用。
    func test_start_idempotentWhileRunning() async {
        probe.results = [false, true]

        await manager.start()
        await manager.start()

        XCTAssertEqual(manager.state, .running)
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func test_setConfiguredPort_persistsValidPort_andRejectsInvalidValue() {
        manager.setConfiguredPort(8088)

        XCTAssertEqual(manager.configuredPort, 8088)
        XCTAssertEqual(userDefaults.integer(forKey: UserDefaultsKeys.dshWebPort), 8088)

        manager.setConfiguredPort(70_000)

        XCTAssertEqual(manager.configuredPort, DSHWebManager.defaultPort)
    }

    func test_start_customPort_usesPortForCommandAndBrowserURL() async {
        manager.setConfiguredPort(8088)
        probe.results = [false, true]

        await manager.start()

        XCTAssertEqual(launcher.lastCommand, DSHWebManager.launchCommand(for: 8088))
        XCTAssertEqual(browser.openedURLs, [URL(string: "http://127.0.0.1:8088")!])
    }

    func test_refreshServices_publishesExternallyStartedServices() async {
        let external = DSHWebService(
            pid: 8123,
            port: 8081,
            command: "node /tmp/@deepseek-ai/dsh/lib/bin.js web --port 8081"
        )
        serviceDiscoverer.services = [external]

        await manager.refreshServices()

        XCTAssertEqual(manager.services, [external])
        XCTAssertEqual(manager.externalServices, [external])
        XCTAssertFalse(manager.isOwnedByApplication(external))
    }

    func test_activePid_andExternalServices_filtersManagedInstance() async {
        XCTAssertNil(manager.activePid)
        XCTAssertTrue(manager.externalServices.isEmpty)

        probe.results = [false, true]
        let handle = FakeProcessHandle(pid: 4242)
        launcher.handles = [handle]

        await manager.start()
        XCTAssertEqual(manager.activePid, 4242)

        let managed = DSHWebService(
            pid: 4242,
            port: 3080,
            command: "node /tmp/@deepseek-ai/dsh/lib/bin.js web --port 3080"
        )
        let external = DSHWebService(
            pid: 8123,
            port: 8081,
            command: "node /tmp/@deepseek-ai/dsh/lib/bin.js web --port 8081"
        )
        serviceDiscoverer.services = [managed, external]

        await manager.refreshServices()

        XCTAssertEqual(manager.services.count, 2)
        XCTAssertTrue(manager.isOwnedByApplication(managed))
        XCTAssertFalse(manager.isOwnedByApplication(external))
        XCTAssertEqual(manager.externalServices, [external])

        await manager.stop()
        XCTAssertNil(manager.activePid)
        XCTAssertEqual(manager.externalServices, [managed, external])
    }

    func test_stopExternalService_rechecksIdentity_thenEscalatesAfterTimeout() async {
        let external = DSHWebService(
            pid: 8123,
            port: 8081,
            command: "node /tmp/@deepseek-ai/dsh/lib/bin.js web --port 8081"
        )
        serviceDiscoverer.services = [external]

        await manager.stop(service: external)

        XCTAssertEqual(signaler.terminatedPIDs, [8123])
        XCTAssertEqual(signaler.forceTerminatedPIDs, [8123])
        XCTAssertGreaterThanOrEqual(serviceDiscoverer.discoverCount, 2)
    }

    func test_stopExternalService_whenIdentityNoLongerMatches_doesNotSignal() async {
        let stale = DSHWebService(
            pid: 8123,
            port: 8081,
            command: "node /tmp/@deepseek-ai/dsh/lib/bin.js web --port 8081"
        )

        await manager.stop(service: stale)

        XCTAssertTrue(signaler.terminatedPIDs.isEmpty)
        XCTAssertTrue(signaler.forceTerminatedPIDs.isEmpty)
    }

    // MARK: - 停止

    /// SIGTERM 后进程正常退出 → stopped，不升级 SIGKILL。
    func test_stop_sendsSIGTERM_transitionsToStopped() async {
        probe.results = [false, true]
        await manager.start()
        guard let handle = launcher.handles.first else {
            return XCTFail("缺进程句柄")
        }

        let stopTask = Task { await manager.stop() }
        // 等 stop() 发出 SIGTERM 并进入等待后模拟进程退出。
        while handle.terminateCount == 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        handle.simulateExit()
        await stopTask.value

        XCTAssertEqual(manager.state, .stopped)
        XCTAssertEqual(handle.terminateCount, 1)
        XCTAssertEqual(handle.forceTerminateCount, 0)
    }

    /// SIGTERM 后进程未退出 → stopTimeout 后 SIGKILL 兜底 → stopped。
    func test_stop_processDoesNotExit_escalatesToSIGKILL() async {
        probe.results = [false, true]
        await manager.start()
        guard let handle = launcher.handles.first else {
            return XCTFail("缺进程句柄")
        }

        await manager.stop()

        XCTAssertEqual(manager.state, .stopped)
        XCTAssertEqual(handle.terminateCount, 1)
        XCTAssertEqual(handle.forceTerminateCount, 1)
    }

    // MARK: - 重启

    /// restart = 先停后启；第二次启动使用新进程句柄。
    func test_restart_stopsThenStarts() async {
        probe.results = [false, true]
        await manager.start()
        guard let first = launcher.handles.first else {
            return XCTFail("缺进程句柄")
        }

        probe.reset()
        probe.results = [false, true]
        let restartTask = Task { await manager.restart() }
        while first.terminateCount == 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        first.simulateExit()
        await restartTask.value

        XCTAssertEqual(manager.state, .running)
        XCTAssertEqual(launcher.launchCount, 2)
        XCTAssertEqual(browser.openedURLs.count, 2)
    }

    /// failed 状态下 restart() 直接重新启动。
    func test_restart_fromFailed_restartsDirectly() async {
        probe.results = [true]
        await manager.start()
        expectFailed(reason: strings.dshWebPortOccupied)

        probe.reset()
        probe.results = [false, true]
        await manager.restart()

        XCTAssertEqual(manager.state, .running)
        XCTAssertEqual(launcher.launchCount, 1)
    }

    // MARK: - 应用退出

    /// shutdown()：SIGTERM 且不升级 SIGKILL，状态重置为 stopped。
    func test_shutdown_terminatesRunningProcess() async {
        probe.results = [false, true]
        await manager.start()
        guard let handle = launcher.handles.first else {
            return XCTFail("缺进程句柄")
        }

        manager.shutdown()

        XCTAssertEqual(handle.terminateCount, 1)
        XCTAssertEqual(handle.forceTerminateCount, 0)
        XCTAssertEqual(manager.state, .stopped)
    }

    /// stopped 状态下 shutdown() 无副作用。
    func test_shutdown_whenStopped_isNoop() {
        manager.shutdown()

        XCTAssertEqual(manager.state, .stopped)
        XCTAssertEqual(launcher.launchCount, 0)
    }

    // MARK: - 日志

    /// 日志缓冲上限 500 行：超出后裁剪旧行，保留最新。
    func test_logBuffer_capsAt500Lines() {
        for index in 0..<520 {
            manager.appendEvent("行 \(index)")
        }

        XCTAssertEqual(manager.logLines.count, 500)
        // 裁剪旧行：保留行 20 … 519。
        XCTAssertTrue(manager.logLines.first?.hasSuffix("行 20") == true)
        XCTAssertTrue(manager.logLines.last?.hasSuffix("行 519") == true)
    }

    /// 事件行带时间戳前缀，原样保留描述。
    func test_logEventLine_hasTimestampPrefix() {
        manager.appendEvent("测试事件")

        XCTAssertEqual(manager.logLines.count, 1)
        let line = manager.logLines[0]
        XCTAssertTrue(line.hasPrefix("["))
        XCTAssertTrue(line.contains("] 测试事件"))
    }

    /// clearLog() 清空缓冲。
    func test_clearLog_emptiesBuffer() {
        manager.appendEvent("a")
        manager.appendEvent("b")

        manager.clearLog()

        XCTAssertTrue(manager.logLines.isEmpty)
    }
}
