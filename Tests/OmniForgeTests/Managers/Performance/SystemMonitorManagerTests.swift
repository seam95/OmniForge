import XCTest
import Combine
@testable import OmniForge

@MainActor
final class SystemMonitorManagerTests: XCTestCase {
    func test_noDemandKeepsSchedulerStopped() {
        let scheduler = FakeRepeatingScheduler()
        let manager = makeManager(scheduler: scheduler)
        XCTAssertEqual(scheduler.activeScheduleCount, 0)
        XCTAssertFalse(manager.isSampling)
    }

    func test_sequencedCPUSamplerWorks() throws {
        let cpu = SequencedCPUSampler(results: [
            .success(CPUUsageReading(total: 0.5, user: 0.3, system: 0.2)),
            .failure(.systemCall("failed")),
        ])
        XCTAssertEqual(try cpu.sample()?.total, 0.5)
        XCTAssertThrowsError(try cpu.sample())
    }

    func test_settingPanelDemandStartsSampling() {
        let scheduler = FakeRepeatingScheduler()
        let manager = makeManager(scheduler: scheduler)
        manager.setPanelDemand(.init(system: true, cpu: true))
        XCTAssertTrue(manager.isSampling)
    }

    func test_setExpandedProcessMetricStartsLoading() {
        let manager = makeManager()
        manager.setExpandedProcessMetric(.cpu)
        XCTAssertEqual(manager.processState.kind, .cpu)
    }

    func test_setExpandedProcessMetricToNilCollapses() {
        let manager = makeManager()
        manager.setExpandedProcessMetric(.cpu)
        manager.setExpandedProcessMetric(nil)
        XCTAssertNil(manager.processState.kind)
    }

    func test_setIntervalUpdatesSamplingTimer() throws {
        let scheduler = FakeRepeatingScheduler()
        let manager = makeManager(scheduler: scheduler)
        manager.setPanelDemand(.init(system: true, cpu: true))
        XCTAssertEqual(scheduler.lastInterval, 2.0)
        try manager.setInterval(seconds: 5)
        XCTAssertEqual(scheduler.lastInterval, 5.0)
    }

    func test_setIntervalRejectsInvalidValues() {
        let manager = makeManager()
        XCTAssertThrowsError(try manager.setInterval(seconds: 3))
        XCTAssertThrowsError(try manager.setInterval(seconds: 0))
    }

    func test_peripheralBatterySamplingOnDemand() {
        let peripheral = FakePeripheralBatterySampler()
        let manager = SystemMonitorManager(
            scheduler: FakeRepeatingScheduler(),
            cpuSampler: FakeCPUSampler(),
            gpuSampler: FakeGPUSampler(),
            memorySampler: FakeMemorySampler(),
            temperatureSampler: FakeTemperatureSampler(),
            networkSampler: FakeNetworkSampler(),
            diskSampler: FakeDiskSampler(),
            powerSampler: FakePowerSampler(),
            peripheralBatterySampler: peripheral,
            processSampler: FakeProcessUsageSampler()
        )
        manager.setPanelDemand(.init(peripheralBattery: true))
        manager.refreshNow()
        // peripheralBattery 采样在后台异步执行，验证 demand 已设置
        XCTAssertTrue(manager.isSampling)
    }

    func test_temperatureFailureExposesIssue() {
        let temp = FailingTemperatureSampler()
        let manager = SystemMonitorManager(
            scheduler: FakeRepeatingScheduler(),
            cpuSampler: FakeCPUSampler(),
            gpuSampler: FakeGPUSampler(),
            memorySampler: FakeMemorySampler(),
            temperatureSampler: temp,
            networkSampler: FakeNetworkSampler(),
            diskSampler: FakeDiskSampler(),
            powerSampler: FakePowerSampler(),
            peripheralBatterySampler: FakePeripheralBatterySampler(),
            processSampler: FakeProcessUsageSampler()
        )
        manager.setPanelDemand(.init(system: true))
        manager.refreshNow()
        // 异步采样，等待主线程更新
        let expectation = XCTestExpectation(description: "temperature failure recorded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertNotNil(manager.snapshot.issues[.cpuTemperature])
            XCTAssertNil(manager.snapshot.cpuTemperature)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    /// SPEC §9.1.4：普通停止保留最近 snapshot/history（下次打开面板立即有内容，
    /// 新采样到达后覆盖）。
    func test_stopSamplingKeepsLastSnapshot() async throws {
        let manager = makeManager()
        manager.setPanelDemand(.init(system: true, cpu: true))
        try await waitForSnapshot(manager) { $0.cpuUsage != nil }
        manager.setPanelDemand(.none)
        XCTAssertFalse(manager.isSampling)
        XCTAssertNotNil(manager.snapshot.sampledAt, "停止后保留最近快照")
    }

    /// SPEC §9.1.2：采样队列忙时，停止采样（离开监控页路径）不得在主线程
    /// 同步等待采样队列。
    func test_stopSamplingWhileQueueBusy_returnsImmediately() {
        let manager = SystemMonitorManager(
            scheduler: TestRepeatingScheduler(),
            cpuSampler: SlowTestCPUSampler(delay: 0.3),
            gpuSampler: TestGPUSampler(),
            memorySampler: TestMemorySampler(),
            temperatureSampler: TestTemperatureSampler(),
            networkSampler: TestNetworkSampler(),
            diskSampler: TestDiskSampler(),
            powerSampler: TestPowerSampler(),
            peripheralBatterySampler: TestPeripheralBatterySampler(),
            processSampler: TestProcessUsageSampler()
        )
        manager.setPanelDemand(.init(system: true))
        // 让慢采样已在串行队列上执行。
        let expectation = expectation(description: "queue busy")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        let start = CFAbsoluteTimeGetCurrent()
        manager.setPanelDemand(.none)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThanOrEqual(
            elapsed, 0.01,
            "停止采样的主线程同步路径不得等待采样队列，实测 \(elapsed)s"
        )
    }

    /// SPEC §9.1.3：generation 令牌使停止后到达的在途采样结果失效，不覆盖状态。
    func test_inFlightSampleResultAfterStop_isDiscarded() async throws {
        let manager = SystemMonitorManager(
            scheduler: TestRepeatingScheduler(),
            cpuSampler: SlowTestCPUSampler(delay: 0.15),
            gpuSampler: TestGPUSampler(),
            memorySampler: TestMemorySampler(),
            temperatureSampler: TestTemperatureSampler(),
            networkSampler: TestNetworkSampler(),
            diskSampler: TestDiskSampler(),
            powerSampler: TestPowerSampler(),
            peripheralBatterySampler: TestPeripheralBatterySampler(),
            processSampler: TestProcessUsageSampler()
        )
        manager.setPanelDemand(.init(cpu: true))
        try await Task.sleep(nanoseconds: 30_000_000) // 慢采样在途
        manager.setPanelDemand(.none) // generation 令牌已换

        let before = manager.snapshot
        try await Task.sleep(nanoseconds: 400_000_000) // 在途结果晚到
        XCTAssertEqual(
            manager.snapshot.sampledAt, before.sampledAt,
            "停止后的在途采样结果必须被丢弃"
        )
    }

    func test_foregroundSamplingAppendsHistory() async throws {
        let manager = makeManager()
        manager.setPanelDemand(.init(system: true, cpu: true))
        try await waitForSnapshot(manager) { $0.cpuUsage != nil }
        XCTAssertFalse(manager.history.cpu.isEmpty)
        XCTAssertFalse(manager.history.gpu.isEmpty)
    }

    func test_backgroundMenuBarSamplingDoesNotAppendHistory() async throws {
        let manager = makeManager()
        manager.setMenuBarMetrics([.cpu])
        try await waitForSnapshot(manager) { $0.cpuUsage != nil }
        XCTAssertTrue(manager.history.cpu.isEmpty)
        XCTAssertTrue(manager.history.gpu.isEmpty)
    }

    func test_stopSamplingKeepsHistory() async throws {
        let manager = makeManager()
        manager.setPanelDemand(.init(system: true, cpu: true))
        try await waitForSnapshot(manager) { $0.cpuUsage != nil }
        XCTAssertFalse(manager.history.cpu.isEmpty)
        manager.setPanelDemand(.none)
        XCTAssertFalse(manager.history.cpu.isEmpty, "停止后保留最近历史（SPEC §9.1.4）")
    }

    func test_menuBarMetricsDriveSampling() {
        let manager = makeManager()
        XCTAssertFalse(manager.isSampling)
        manager.setMenuBarMetrics([.cpu])
        XCTAssertTrue(manager.isSampling)
        manager.setMenuBarMetrics([])
        XCTAssertFalse(manager.isSampling)
    }

    func test_gpuUsageIsStabilizedAcrossSamples() async throws {
        let gpu = ScriptedGPUSampler(values: [0.1, 0.9])
        let manager = SystemMonitorManager(
            scheduler: FakeRepeatingScheduler(),
            cpuSampler: FakeCPUSampler(),
            gpuSampler: gpu,
            memorySampler: FakeMemorySampler(),
            temperatureSampler: FakeTemperatureSampler(),
            networkSampler: FakeNetworkSampler(),
            diskSampler: FakeDiskSampler(),
            powerSampler: FakePowerSampler(),
            peripheralBatterySampler: FakePeripheralBatterySampler(),
            processSampler: FakeProcessUsageSampler()
        )

        manager.setPanelDemand(.init(gpu: true))
        try await waitForSnapshot(manager) { $0.gpuUsage != nil }
        XCTAssertEqual(manager.snapshot.gpuUsage!, 0.1, accuracy: 0.0001)

        manager.refreshNow()
        try await waitForSnapshot(manager) { snapshot in
            guard let usage = snapshot.gpuUsage else { return false }
            return abs(usage - 0.1) > 0.0001
        }

        let stabilized = try XCTUnwrap(manager.snapshot.gpuUsage)
        XCTAssertLessThanOrEqual(stabilized, 0.3 + 0.0001)
        XCTAssertEqual(stabilized, 0.3, accuracy: 0.0001)
    }

    func test_diskRefreshMetadataUsesForegroundDemand() async throws {
        let scheduler = FakeRepeatingScheduler()
        let disk = FakeDiskSampler()
        let manager = SystemMonitorManager(
            scheduler: scheduler,
            cpuSampler: FakeCPUSampler(),
            gpuSampler: FakeGPUSampler(),
            memorySampler: FakeMemorySampler(),
            temperatureSampler: FakeTemperatureSampler(),
            networkSampler: FakeNetworkSampler(),
            diskSampler: disk,
            powerSampler: FakePowerSampler(),
            peripheralBatterySampler: FakePeripheralBatterySampler(),
            processSampler: FakeProcessUsageSampler()
        )

        // 前台面板：refreshMetadata == true
        manager.setPanelDemand(.init(disk: true))
        try await waitForSnapshot(manager) { _ in disk.callCount >= 1 }
        XCTAssertEqual(disk.lastRefreshMetadata, true)
    }

    func test_stopSamplingStopsActiveProcessSampler() {
        let process = FakeProcessUsageSampler()
        let manager = SystemMonitorManager(
            scheduler: FakeRepeatingScheduler(),
            cpuSampler: FakeCPUSampler(),
            gpuSampler: FakeGPUSampler(),
            memorySampler: FakeMemorySampler(),
            temperatureSampler: FakeTemperatureSampler(),
            networkSampler: FakeNetworkSampler(),
            diskSampler: FakeDiskSampler(),
            powerSampler: FakePowerSampler(),
            peripheralBatterySampler: FakePeripheralBatterySampler(),
            processSampler: process
        )

        manager.setPanelDemand(.init(cpu: true))
        manager.setExpandedProcessMetric(.cpu)
        XCTAssertEqual(manager.processState.kind, .cpu)

        manager.setPanelDemand(.none)
        XCTAssertNil(manager.processState.kind)
        XCTAssertEqual(process.stoppedKinds, [.cpu])
    }

    func test_refreshNow_forceProcess_bypassesThrottle() async throws {
        let process = CountingProcessUsageSampler()
        let manager = SystemMonitorManager(
            scheduler: FakeRepeatingScheduler(),
            cpuSampler: FakeCPUSampler(),
            gpuSampler: FakeGPUSampler(),
            memorySampler: FakeMemorySampler(),
            temperatureSampler: FakeTemperatureSampler(),
            networkSampler: FakeNetworkSampler(),
            diskSampler: FakeDiskSampler(),
            powerSampler: FakePowerSampler(),
            peripheralBatterySampler: FakePeripheralBatterySampler(),
            processSampler: process
        )

        manager.setPanelDemand(.init(cpu: true))
        manager.setExpandedProcessMetric(.cpu)
        // Initial expand samples once.
        try await waitForProcessSampleCount(process, atLeast: 1)
        let afterExpand = process.sampleCount

        // Immediate non-force refresh should not re-sample process (4s throttle).
        manager.refreshNow()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(process.sampleCount, afterExpand)

        manager.refreshNow(forceProcess: true)
        try await waitForProcessSampleCount(process, atLeast: afterExpand + 1)
        XCTAssertGreaterThanOrEqual(process.sampleCount, afterExpand + 1)
    }

    func test_startSamplingPrimesProcessBaselines() async throws {
        let process = RecordingProcessUsageSampler()
        let manager = SystemMonitorManager(
            scheduler: FakeRepeatingScheduler(),
            cpuSampler: FakeCPUSampler(),
            gpuSampler: FakeGPUSampler(),
            memorySampler: FakeMemorySampler(),
            temperatureSampler: FakeTemperatureSampler(),
            networkSampler: FakeNetworkSampler(),
            diskSampler: FakeDiskSampler(),
            powerSampler: FakePowerSampler(),
            peripheralBatterySampler: FakePeripheralBatterySampler(),
            processSampler: process
        )

        manager.setPanelDemand(.init(system: true))
        try await waitForPrimeCount(process, atLeast: 1)

        // 仅预热 GPU/网络；CPU/内存/energy 不应进入 prime 调用。
        XCTAssertEqual(Set(process.primedKinds), [.gpu, .network])
    }

    func test_processSampleWithoutBaselineStaysLoading() async throws {
        // 首次返回空 + 无基线 => 保持 loading，不切 .loaded(_, [])
        let process = PrimingProcessUsageSampler()
        let manager = SystemMonitorManager(
            scheduler: FakeRepeatingScheduler(),
            cpuSampler: FakeCPUSampler(),
            gpuSampler: FakeGPUSampler(),
            memorySampler: FakeMemorySampler(),
            temperatureSampler: FakeTemperatureSampler(),
            networkSampler: FakeNetworkSampler(),
            diskSampler: FakeDiskSampler(),
            powerSampler: FakePowerSampler(),
            peripheralBatterySampler: FakePeripheralBatterySampler(),
            processSampler: process
        )

        manager.setPanelDemand(.init(gpu: true))
        manager.setExpandedProcessMetric(.gpu)
        // hasProcessBaseline 在主线程先于采样执行（sampleProcessUsage 前置查询），
        // sampleCount>=1 即代表查询与采样均已完成；再等一拍让主线程回写 processState。
        try await waitForPrimingSampleCount(process, atLeast: 1)
        try await Task.sleep(nanoseconds: 100_000_000) // 等主线程回写完成
        XCTAssertEqual(process.sampleCount, 1)
        XCTAssertTrue(process.hasBaselineQueried)
        // 采样完成后应维持 .loading，而非切到 .loaded（预热态）。
        if case .loaded = manager.processState {
            XCTFail("预热态不应切到 .loaded")
        }
        if case .loading = manager.processState {
        } else {
            XCTFail("预期维持 .loading，实际为 \(manager.processState)")
        }
    }

    func test_processSampleWithBaselineAndEmptyShowsLoaded() async throws {
        // 空返回但有基线 => 切 .loaded(_, [])（真无数据，由 UI 显示 empty）
        let process = BaselineReadyProcessUsageSampler()
        let manager = SystemMonitorManager(
            scheduler: FakeRepeatingScheduler(),
            cpuSampler: FakeCPUSampler(),
            gpuSampler: FakeGPUSampler(),
            memorySampler: FakeMemorySampler(),
            temperatureSampler: FakeTemperatureSampler(),
            networkSampler: FakeNetworkSampler(),
            diskSampler: FakeDiskSampler(),
            powerSampler: FakePowerSampler(),
            peripheralBatterySampler: FakePeripheralBatterySampler(),
            processSampler: process
        )

        manager.setPanelDemand(.init(gpu: true))
        manager.setExpandedProcessMetric(.gpu)
        try await waitForProcessState(manager) { state in
            if case .loaded(.gpu, let rows) = state { return rows.isEmpty }
            return false
        }
        XCTAssertEqual(process.sampleCount, 1)
    }

    func test_firstSampleWithoutBaseline_keepsLoadingAndFollowsUp() async throws {
        // delta 类指标（GPU/网络）首开：首采仅建基线必返回空，不应切 loaded([]) 空态
        // 干等 4s 节流 tick；应保持 loading，由 ~1s 后的自动补采产出真实数据。
        let process = FirstEmptyThenRowsProcessUsageSampler()
        let manager = SystemMonitorManager(
            scheduler: FakeRepeatingScheduler(),
            cpuSampler: FakeCPUSampler(),
            gpuSampler: FakeGPUSampler(),
            memorySampler: FakeMemorySampler(),
            temperatureSampler: FakeTemperatureSampler(),
            networkSampler: FakeNetworkSampler(),
            diskSampler: FakeDiskSampler(),
            powerSampler: FakePowerSampler(),
            peripheralBatterySampler: FakePeripheralBatterySampler(),
            processSampler: process
        )

        manager.setPanelDemand(.init(gpu: true))
        manager.setExpandedProcessMetric(.gpu)

        // 首采回写完成后（补采 1s 未到）应保持 loading，而非 loaded(空) 假空态
        try await waitForFirstEmptySampleCount(process, atLeast: 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        if case .loading = manager.processState {
        } else {
            XCTFail("首开仅建基线，应保持 .loading，实际为 \(manager.processState)")
        }

        // ~1s 后自动补采出数，全程无需手动刷新或定时 tick
        try await waitForProcessState(manager, timeout: 2.5) { state in
            if case .loaded(.gpu, let rows) = state { return !rows.isEmpty }
            return false
        }
        XCTAssertEqual(process.sampleCount, 2)
    }

    func test_collapseDuringFollowUpWait_cancelsResample() async throws {
        // 首开补采等待期内收起排行：补采任务必须取消，不得再采样
        let process = FirstEmptyThenRowsProcessUsageSampler()
        let manager = SystemMonitorManager(
            scheduler: FakeRepeatingScheduler(),
            cpuSampler: FakeCPUSampler(),
            gpuSampler: FakeGPUSampler(),
            memorySampler: FakeMemorySampler(),
            temperatureSampler: FakeTemperatureSampler(),
            networkSampler: FakeNetworkSampler(),
            diskSampler: FakeDiskSampler(),
            powerSampler: FakePowerSampler(),
            peripheralBatterySampler: FakePeripheralBatterySampler(),
            processSampler: process
        )

        manager.setPanelDemand(.init(gpu: true))
        manager.setExpandedProcessMetric(.gpu)
        try await waitForFirstEmptySampleCount(process, atLeast: 1)
        try await Task.sleep(nanoseconds: 100_000_000) // 等主线程回写调度补采

        manager.setExpandedProcessMetric(nil)
        // 越过 1s 补采时刻，不得发生第二次采样
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(process.sampleCount, 1)
    }

    // MARK: - 进程采样队列隔离（修复：nettop 阻塞共享采样队列，菜单栏指标停更）

    /// 共享指标采样串行队列的 label（SystemMonitorManager 内部常量）。
    private static let sharedSamplingQueueLabel = "com.omniforge.system-monitor"

    func test_processSampleRunsOffSharedSamplingQueue() async throws {
        // 回归锁（批次 E 性能）：进程排行采样内部跑 nettop 子进程（1-3s 起），
        // 曾与全部指标采样共用一条串行队列——展开网络排行期间菜单栏指标
        // 停更最长 5.5s。断言：sample 执行不在共享采样队列上；
        // loaded 状态在主 actor 可见即证明结果仍回主线程回写。
        let process = QueueRecordingProcessUsageSampler()
        let manager = SystemMonitorManager(
            scheduler: FakeRepeatingScheduler(),
            cpuSampler: FakeCPUSampler(),
            gpuSampler: FakeGPUSampler(),
            memorySampler: FakeMemorySampler(),
            temperatureSampler: FakeTemperatureSampler(),
            networkSampler: FakeNetworkSampler(),
            diskSampler: FakeDiskSampler(),
            powerSampler: FakePowerSampler(),
            peripheralBatterySampler: FakePeripheralBatterySampler(),
            processSampler: process
        )

        manager.setPanelDemand(.init(network: true))
        manager.setExpandedProcessMetric(.network)

        // 等待采样完成且回写主线程（loaded 在主 actor 上轮询可见）
        try await waitForProcessState(manager, timeout: 2.0) { state in
            if case .loaded(.network, _) = state { return true }
            return false
        }
        let labels = process.recordedLabels(for: "sample")
        XCTAssertFalse(labels.isEmpty, "进程排行采样应已执行")
        for label in labels {
            XCTAssertNotEqual(
                label, Self.sharedSamplingQueueLabel,
                "进程排行采样不得在共享采样串行队列上执行（nettop 会阻塞菜单栏指标更新），实际队列: \(label)"
            )
        }
    }

    func test_processBaselinePrimingRunsOffSharedSamplingQueue() async throws {
        // 基线预热同样会跑 nettop（网络 delta 基线）与 IORegistry 枚举（GPU），
        // 也不得占用共享采样队列——否则面板一打开菜单栏指标就停更 1-3s。
        let process = QueueRecordingProcessUsageSampler()
        let manager = SystemMonitorManager(
            scheduler: FakeRepeatingScheduler(),
            cpuSampler: FakeCPUSampler(),
            gpuSampler: FakeGPUSampler(),
            memorySampler: FakeMemorySampler(),
            temperatureSampler: FakeTemperatureSampler(),
            networkSampler: FakeNetworkSampler(),
            diskSampler: FakeDiskSampler(),
            powerSampler: FakePowerSampler(),
            peripheralBatterySampler: FakePeripheralBatterySampler(),
            processSampler: process
        )

        manager.setPanelDemand(.init(system: true))
        try await waitForQueueRecordedCalls(process, atLeast: 1)

        let labels = process.recordedLabels(for: "prime")
        XCTAssertFalse(labels.isEmpty, "基线预热应已执行")
        for label in labels {
            XCTAssertNotEqual(
                label, Self.sharedSamplingQueueLabel,
                "基线预热不得在共享采样串行队列上执行，实际队列: \(label)"
            )
        }
    }

    func test_memorySampleFailureClearsPressureToUnknown() async throws {
        let memory = ScriptedMemorySampler(results: [
            .success(MemoryReading(used: 4_000_000_000, total: 8_000_000_000, pressure: .critical)),
            .failure(MetricSamplingError.systemCall("vm_stats failed")),
        ])
        let manager = SystemMonitorManager(
            scheduler: FakeRepeatingScheduler(),
            cpuSampler: FakeCPUSampler(),
            gpuSampler: FakeGPUSampler(),
            memorySampler: memory,
            temperatureSampler: FakeTemperatureSampler(),
            networkSampler: FakeNetworkSampler(),
            diskSampler: FakeDiskSampler(),
            powerSampler: FakePowerSampler(),
            peripheralBatterySampler: FakePeripheralBatterySampler(),
            processSampler: FakeProcessUsageSampler()
        )

        manager.setPanelDemand(.init(memory: true))
        try await waitForSnapshot(manager) { $0.memoryPressure == .critical && $0.memoryUsed != nil }
        XCTAssertEqual(manager.snapshot.memoryPressure, .critical)

        manager.refreshNow()
        try await waitForSnapshot(manager) { snapshot in
            snapshot.issues[.memory] != nil && snapshot.memoryUsed == nil
        }
        XCTAssertNil(manager.snapshot.memoryUsed)
        XCTAssertNil(manager.snapshot.memoryTotal)
        XCTAssertEqual(manager.snapshot.memoryPressure, .unknown)
        XCTAssertNotNil(manager.snapshot.issues[.memory])
    }

    func test_menuBarCPUOnlySamplesCPUSamplerAcrossTicks() async throws {
        // Phase F：仅菜单栏 CPU 时不应采 network/disk/power/memory/gpu/temperature；
        // 验证即时 tick 与后续 scheduled tick 均只采 CPU
        let scheduler = FakeRepeatingScheduler()
        let samplers = FakeSamplerSet()
        let manager = makeManager(scheduler: scheduler, samplers: samplers)

        manager.setMenuBarMetrics([.cpu])
        try await waitForSnapshot(manager) { _ in samplers.cpu.callCount >= 1 }

        // 推进 2 个 scheduled tick，确认其它 sampler 仍为 0
        scheduler.fire()
        try await Task.sleep(nanoseconds: 30_000_000)
        scheduler.fire()
        try await waitForSnapshot(manager) { _ in samplers.cpu.callCount >= 3 }

        XCTAssertGreaterThanOrEqual(samplers.cpu.callCount, 3)
        XCTAssertEqual(samplers.gpu.callCount, 0)
        XCTAssertEqual(samplers.memory.callCount, 0)
        XCTAssertEqual(samplers.network.callCount, 0)
        XCTAssertEqual(samplers.disk.callCount, 0)
        XCTAssertEqual(samplers.power.callCount, 0)
        XCTAssertEqual(samplers.temperature.callCount, 0)
        XCTAssertEqual(samplers.peripheralBattery.callCount, 0)
        XCTAssertEqual(manager.activeMenuBarMetrics, [.cpu])
    }

    // MARK: - 面板打开立即采样（修复：菜单栏常驻采样时打开面板不再等下一个 tick）

    func test_openingPanelWhileMenuBarSamplingSamplesImmediately() async throws {
        // 用户开启菜单栏指标时采样器早已运行，setPanelDemand 走不到 startSampling
        // 的即时采样——必须在面板打开边沿补采，否则 GPU 等面板指标要等下一个 tick
        let scheduler = FakeRepeatingScheduler()
        let samplers = FakeSamplerSet()
        let manager = makeManager(scheduler: scheduler, samplers: samplers)

        manager.setMenuBarMetrics([.cpu])
        try await waitForSnapshot(manager) { _ in samplers.cpu.callCount >= 1 }
        XCTAssertEqual(samplers.gpu.callCount, 0, "菜单栏仅 CPU，GPU 不应被采样")

        // 打开面板：不推进任何定时 tick，GPU 应被立即补采
        manager.setPanelDemand(.init(gpu: true))
        try await waitForSnapshot(manager) { $0.gpuUsage != nil }
        XCTAssertGreaterThanOrEqual(samplers.gpu.callCount, 1)
    }

    func test_openingPanelFromColdDoesNotDoubleSample() async throws {
        // 无菜单栏需求时打开面板走 startSampling 即时采样；补采分支不得再触发一轮
        let samplers = FakeSamplerSet()
        let manager = makeManager(samplers: samplers)

        manager.setPanelDemand(.init(cpu: true))
        try await waitForSnapshot(manager) { _ in samplers.cpu.callCount >= 1 }
        // 0.25s 内只允许即时一轮（0.5s 的 follow-up 尚未到期）
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(samplers.cpu.callCount, 1)
    }

    func test_panelOpenSamplesDoNotAppendHistory() async throws {
        // 补采与 follow-up 均为非定时点，不得追加 history（破坏折线等距 x 轴）
        let samplers = FakeSamplerSet()
        let manager = makeManager(samplers: samplers)

        manager.setMenuBarMetrics([.cpu])
        try await waitForSnapshot(manager) { $0.cpuUsage != nil }
        XCTAssertTrue(manager.history.cpu.isEmpty)

        manager.setPanelDemand(.init(cpu: true))
        try await waitForSnapshot(manager) { _ in samplers.cpu.callCount >= 2 }
        // 越过 0.5s follow-up
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(manager.history.cpu.isEmpty, "补采与 follow-up 不应追加趋势历史")
    }

    func test_closingPanelCancelsRapidFollowUp() async throws {
        // 面板打开后立即关闭：0.5s follow-up 必须被守卫拦下（关闭零开销设计）
        let samplers = FakeSamplerSet()
        let manager = makeManager(samplers: samplers)

        manager.setMenuBarMetrics([.cpu])
        try await waitForSnapshot(manager) { _ in samplers.cpu.callCount >= 1 }
        let gpuBefore = samplers.gpu.callCount

        manager.setPanelDemand(.init(gpu: true))
        manager.setPanelDemand(.none)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertLessThanOrEqual(samplers.gpu.callCount, gpuBefore + 1, "follow-up 不应在面板关闭后触发")
    }

    // MARK: - 启动首轮采样（修复：后台 stride 跳过首采，菜单栏指标十几秒才出数）

    func test_backgroundFirstTickSamplesAllMenuBarMetrics() async throws {
        // 启动时面板未打开（isForeground=false），后台 stride 会让 GPU/磁盘等
        // 第 5 个 tick、温度与电池第 8 个 tick（10~16s）才首次采样。首轮必须
        // 无视 stride 全采一遍，否则菜单栏长时间显示 "--"。
        let scheduler = FakeRepeatingScheduler()
        let samplers = FakeSamplerSet()
        let manager = makeManager(scheduler: scheduler, samplers: samplers)

        manager.setMenuBarMetrics([
            .cpu, .gpu, .memory,
            .cpuTemperature, .gpuTemperature, .batteryTemperature,
            .battery,
        ])

        // 不推进任何定时 tick：只靠 startSampling 的即时首轮就要出数
        try await waitForSnapshot(manager) { snapshot in
            snapshot.cpuUsage != nil && snapshot.gpuUsage != nil
                && snapshot.memoryUsed != nil && snapshot.power != nil
                && snapshot.cpuTemperature != nil && snapshot.gpuTemperature != nil
                && snapshot.batteryTemperature != nil
        }
        XCTAssertGreaterThanOrEqual(samplers.gpu.callCount, 1)
        XCTAssertGreaterThanOrEqual(samplers.temperature.callCount, 3, "三种温度都应首轮采集")
        XCTAssertGreaterThanOrEqual(samplers.power.callCount, 1)
        XCTAssertEqual(scheduler.activeScheduleCount, 1, "首轮即时采样不应额外占用调度")
    }

    func test_backgroundStrideResumesAfterFirstReading() async throws {
        // 首轮建好读数后必须回到 stride 降频：GPU 后台 stride=5，
        // 第 2~4 个 tick 不得重复采样（否则降频设计失效）。
        let scheduler = FakeRepeatingScheduler()
        let samplers = FakeSamplerSet()
        let manager = makeManager(scheduler: scheduler, samplers: samplers)

        manager.setMenuBarMetrics([.cpu, .gpu])
        try await waitForSnapshot(manager) { $0.gpuUsage != nil }
        XCTAssertEqual(samplers.gpu.callCount, 1, "首轮只应采一次 GPU")

        for _ in 0..<3 { scheduler.fire() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(samplers.gpu.callCount, 1, "GPU 后台 stride=5，第 2~4 tick 不应重复采样")
        XCTAssertGreaterThanOrEqual(samplers.cpu.callCount, 4, "CPU stride=1 仍每 tick 采样")
    }

    func test_samplingDecisionSnapshotsTickAtDispatch() async throws {
        // 回归锁（数据竞争闪退修复）：一轮采样采哪些指标必须在发起时（主线程）判定，
        // 不得延迟到采样队列闭包执行时再读 tickCount——闭包执行前主线程可能已推进到
        // 下一个 tick，且跨线程读取主线程状态本身是未定义行为。
        // 场景：gpu 后台 stride=5（baseTick=2），tick5 发起时应采 gpu，紧接 tick6
        // 发起（不采）。两轮闭包入队后串行执行，执行时 tickCount 已是 6，判定必须
        // 仍按各自发起轮的快照——否则 tick5 轮的 gpu 采样会凭空丢失。
        let scheduler = FakeRepeatingScheduler()
        let samplers = FakeSamplerSet()
        let manager = makeManager(scheduler: scheduler, samplers: samplers)

        manager.setMenuBarMetrics([.cpu, .gpu])
        try await waitForSnapshot(manager) { $0.gpuUsage != nil }
        XCTAssertEqual(samplers.gpu.callCount, 1, "首轮全采应采 gpu 一次")

        // 推进 tick2~tick4（非 stride 点，gpu 不采），并等队列排空
        for _ in 0..<3 {
            scheduler.fire()
            try await waitForCPUSampleCount(samplers.cpu, atLeast: samplers.cpu.callCount + 1)
        }

        // 关键时序：连续发起 tick5 与 tick6，两次 fire 之间不等待。
        // 采样闭包尚未执行，执行时 tickCount 必已推进到 6。
        scheduler.fire()
        scheduler.fire()
        try await waitForCPUSampleCount(samplers.cpu, atLeast: 6)

        XCTAssertEqual(
            samplers.gpu.callCount, 2,
            "tick5 轮的 gpu 采样不得因闭包执行时 tickCount 已推进到 6 而丢失"
        )
    }

    // MARK: - 调度回调线程契约（修复：定时采样回调切回主线程）

    /// 回归锁（2d80ab8 同族残留根因）：`TimerRepeatingScheduler` 的
    /// DispatchSourceTimer 未指定 target queue，定时回调（action）在全局并发
    /// 队列直调 `@MainActor` 的 sampleAll()——tickCount / forcedSampleAttempts /
    /// snapshot 被跨线程写入（Swift 5 模式无运行时隔离检查，静默数据竞争）。
    ///
    /// 线程契约：调度闭包必须把 sampleAll 派回主队列执行。
    /// 暴露方式：在全局队列 fire 一次定时 tick 后阻塞主线程——
    /// 旧缺陷下 sampleAll 已在 fire 线程同步发起采样（不依赖主线程），
    /// CPU 采样照常发生；契约满足时它必须等主队列恢复才执行。
    func test_scheduledTickFromGlobalQueueDispatchesSampleToMainThread() async throws {
        let scheduler = GlobalQueueFiringScheduler()
        let samplers = FakeSamplerSet()
        let manager = makeManager(scheduler: scheduler, samplers: samplers)

        manager.setMenuBarMetrics([.cpu])
        try await waitForSnapshot(manager) { $0.cpuUsage != nil }
        let baseline = samplers.cpu.callCount

        // 在全局并发队列上触发一次定时 tick（复刻 TimerRepeatingScheduler 的回调线程）
        scheduler.fireOnGlobalQueue()
        // 阻塞主线程：派回主队列的 sampleAll 尚无法执行；
        // 若调度闭包未切回主线程（旧缺陷），采样已在全局队列同步发起。
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(
            samplers.cpu.callCount, baseline,
            "主线程阻塞期间定时 tick 不得发起采样：sampleAll 必须经主队列派发"
        )

        // 主线程恢复后采样正常完成，状态更新对主线程可见
        try await waitForSnapshot(manager, timeout: 2.0) { _ in
            samplers.cpu.callCount > baseline
        }
        // 契约断言：更新后的状态在主 actor 上读取（不崩溃即通过）
        MainActor.assumeIsolated {
            XCTAssertNotNil(manager.snapshot.cpuUsage)
        }
    }

    func test_menuBarNetworkGetsRapidFollowUpWithoutPanelDemand() async throws {
        // 网速是 delta 指标：首轮只建基线、速率必为 nil。启动时面板未打开，
        // 0.5s 补采必须放行，否则要干等 2s 后的下一个定时 tick 才出速率。
        let network = BaselineThenRateNetworkSampler()
        let manager = SystemMonitorManager(
            scheduler: FakeRepeatingScheduler(),
            cpuSampler: FakeCPUSampler(),
            gpuSampler: FakeGPUSampler(),
            memorySampler: FakeMemorySampler(),
            temperatureSampler: FakeTemperatureSampler(),
            networkSampler: network,
            diskSampler: FakeDiskSampler(),
            powerSampler: FakePowerSampler(),
            peripheralBatterySampler: FakePeripheralBatterySampler(),
            processSampler: FakeProcessUsageSampler()
        )

        manager.setMenuBarMetrics([.network])
        // 不推进定时 tick：速率应由 0.5s 后的补采产出
        try await waitForSnapshot(manager, timeout: 2.0) { $0.netDownBytesPerSec != nil }
        XCTAssertGreaterThanOrEqual(network.callCount, 2)
        XCTAssertEqual(try XCTUnwrap(manager.snapshot.netDownBytesPerSec), 1024, accuracy: 0.001)
    }

    func test_rapidFollowUpSkippedWithoutNetworkDemand() async throws {
        // 无面板需求且菜单栏无网速指标时，0.5s 补采不得触发（后台零开销设计）
        let samplers = FakeSamplerSet()
        let manager = makeManager(samplers: samplers)

        manager.setMenuBarMetrics([.cpu])
        try await waitForSnapshot(manager) { $0.cpuUsage != nil }
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(samplers.cpu.callCount, 1, "无网速需求时不应触发补采")
    }

    func test_backgroundStrideResumesWhenSamplerNeverReturnsReading() async throws {
        // 回归锁：采样器长期返回「无数据」且不抛错时（无 GPU 利用率 / 无温度 HID 通道 /
        // 无外设电池），强制采样必须封顶。否则该指标会被永久改成每 tick 采样，
        // 击穿后台降频——温度每轮还会多做一次 HID 服务枚举。
        let scheduler = FakeRepeatingScheduler()
        let gpu = NilGPUSampler()
        let manager = SystemMonitorManager(
            scheduler: scheduler,
            cpuSampler: FakeCPUSampler(),
            gpuSampler: gpu,
            memorySampler: FakeMemorySampler(),
            temperatureSampler: FakeTemperatureSampler(),
            networkSampler: FakeNetworkSampler(),
            diskSampler: FakeDiskSampler(),
            powerSampler: FakePowerSampler(),
            peripheralBatterySampler: FakePeripheralBatterySampler(),
            processSampler: FakeProcessUsageSampler()
        )

        manager.setMenuBarMetrics([.gpu])
        try await waitForSnapshot(manager) { $0.sampledAt != nil }
        XCTAssertEqual(gpu.callCount, 1, "首轮必须采样一次")
        XCTAssertNil(manager.snapshot.gpuUsage)

        // 缺读数宽容期：首轮之外的连续 3 个 tick 继续强制补采
        for _ in 0..<3 {
            scheduler.fire()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(gpu.callCount, 4, "缺读数时按上限连续强制采样")

        // 封顶后交回 stride=5：tick 5 踩中 stride 采一次，tick 6~9 都不采
        scheduler.fire()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(gpu.callCount, 5, "tick 5 踩中 stride 采样一次")
        for _ in 0..<4 {
            scheduler.fire()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(gpu.callCount, 5, "封顶后必须回到 stride 降频，不得每 tick 都采")
    }

    func test_forcedSampleBudgetResetsWhenMetricReenabled() async throws {
        // 指标被停用后重新勾选应重新获得强制采样预算：否则一个"无数据"指标
        // 重新启用时要干等一整个 stride（GPU 10s / 温度 16s）。
        let scheduler = FakeRepeatingScheduler()
        let gpu = NilGPUSampler()
        let manager = SystemMonitorManager(
            scheduler: scheduler,
            cpuSampler: FakeCPUSampler(),
            gpuSampler: gpu,
            memorySampler: FakeMemorySampler(),
            temperatureSampler: FakeTemperatureSampler(),
            networkSampler: FakeNetworkSampler(),
            diskSampler: FakeDiskSampler(),
            powerSampler: FakePowerSampler(),
            peripheralBatterySampler: FakePeripheralBatterySampler(),
            processSampler: FakeProcessUsageSampler()
        )

        manager.setMenuBarMetrics([.gpu])
        try await waitForSnapshot(manager) { $0.sampledAt != nil }
        // 用尽预算：首轮 + 连续 3 次强制
        for _ in 0..<3 {
            scheduler.fire()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(gpu.callCount, 4)

        // 停用 GPU 并推进一个 tick（预算随停用一起清掉），再重新启用
        manager.setMenuBarMetrics([.cpu])
        scheduler.fire()
        try await Task.sleep(nanoseconds: 100_000_000)
        manager.setMenuBarMetrics([.cpu, .gpu])

        // tick 6 恰好踩中 GPU stride=5（无论如何都会采），取作基线；
        // tick 7 是非 stride 点，只有"重新获得强制采样预算"才会采。
        scheduler.fire()
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterStrideAlignedTick = gpu.callCount
        scheduler.fire()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(
            gpu.callCount, afterStrideAlignedTick,
            "重新启用的指标应重新获得强制采样预算，而非干等一整个 stride"
        )
    }

    func test_newlyEnabledMenuBarMetricIsSampledOnNextTick() async throws {
        // 会话中途新启用指标（用户在设置里勾选 GPU / 温度）不得干等 stride：
        // 该指标尚无读数，下一个 tick 即强制采样。
        let scheduler = FakeRepeatingScheduler()
        let samplers = FakeSamplerSet()
        let manager = makeManager(scheduler: scheduler, samplers: samplers)

        manager.setMenuBarMetrics([.cpu])
        try await waitForSnapshot(manager) { $0.cpuUsage != nil }
        XCTAssertEqual(samplers.gpu.callCount, 0)
        XCTAssertEqual(samplers.temperature.callCount, 0)

        manager.setMenuBarMetrics([.cpu, .gpu, .cpuTemperature])
        // 只推进一个 tick：GPU（stride=5）与温度（stride=8）都应已出数
        scheduler.fire()
        try await waitForSnapshot(manager) { $0.gpuUsage != nil && $0.cpuTemperature != nil }
        XCTAssertGreaterThanOrEqual(samplers.gpu.callCount, 1)
        XCTAssertGreaterThanOrEqual(samplers.temperature.callCount, 1)
    }
}

// MARK: - Test Helpers

final class FakeRepeatingScheduler: RepeatingScheduling {
    var activeScheduleCount = 0
    var lastInterval: TimeInterval = 0
    private var action: (() -> Void)?

    func schedule(every interval: TimeInterval, _ action: @escaping () -> Void) -> AnyCancellable {
        lastInterval = interval
        activeScheduleCount += 1
        self.action = action
        return AnyCancellable { [weak self] in
            self?.activeScheduleCount -= 1
            self?.action = nil
        }
    }

    /// 手动推进一次定时采样（不触发 startSampling 时的即时 sampleAll）
    func fire() {
        action?()
    }
}

/// 模拟 TimerRepeatingScheduler 的真实线程行为：DispatchSourceTimer 未指定
/// target queue 时，定时回调（action）在全局并发队列上被执行。
/// 用于验证调度闭包把 sampleAll 派回主队列的线程契约。
final class GlobalQueueFiringScheduler: RepeatingScheduling {
    private var action: (() -> Void)?
    private let lock = NSLock()

    func schedule(every interval: TimeInterval, _ action: @escaping () -> Void) -> AnyCancellable {
        lock.lock()
        self.action = action
        lock.unlock()
        return AnyCancellable { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.action = nil
            self.lock.unlock()
        }
    }

    /// 在全局并发队列上触发一次定时回调（复刻 TimerRepeatingScheduler 的回调线程）。
    func fireOnGlobalQueue() {
        lock.lock()
        let action = action
        lock.unlock()
        DispatchQueue.global().async { action?() }
    }
}

final class FakeCPUSampler: CPUUsageSampling {
    var callCount = 0
    func sample() throws -> CPUUsageReading? {
        callCount += 1
        return CPUUsageReading(total: 0.5, user: 0.3, system: 0.2)
    }
}

final class FakeTemperatureSampler: TemperatureSampling {
    var callCount = 0
    func sampleCPU() throws -> Double? { callCount += 1; return 50 }
    func sampleGPU() throws -> Double? { callCount += 1; return 50 }
    func sampleBattery() throws -> Double? { callCount += 1; return 50 }
}

final class FailingTemperatureSampler: TemperatureSampling {
    func sampleCPU() throws -> Double? {
        throw MetricSamplingError.systemCall("SMC not available")
    }
    func sampleGPU() throws -> Double? {
        throw MetricSamplingError.systemCall("SMC not available")
    }
    func sampleBattery() throws -> Double? {
        throw MetricSamplingError.systemCall("SMC not available")
    }
}

final class FakeGPUSampler: GPUUsageSampling {
    var callCount = 0
    func sample() throws -> Double? { callCount += 1; return 0.3 }
}

/// 模拟「成功但无读数」的采样器（如无 GPU 利用率的机器）：不抛错，恒返回 nil。
final class NilGPUSampler: GPUUsageSampling {
    private(set) var callCount = 0
    func sample() throws -> Double? { callCount += 1; return nil }
}

final class ScriptedGPUSampler: GPUUsageSampling {
    var values: [Double?]

    init(values: [Double?]) {
        self.values = values
    }

    func sample() throws -> Double? {
        defer { if !values.isEmpty { values.removeFirst() } }
        return values.first ?? nil
    }
}

final class FakeNetworkSampler: NetworkSampling {
    var callCount = 0
    func sample(now: TimeInterval) throws -> NetworkReading {
        callCount += 1
        return .init(downBytesPerSec: 0, upBytesPerSec: 0, totalDown: 0, totalUp: 0)
    }
}

/// 模拟真实 NetworkSampler 的 delta 行为：首采仅建基线（速率 nil），此后给出真实速率。
final class BaselineThenRateNetworkSampler: NetworkSampling {
    private(set) var callCount = 0
    func sample(now: TimeInterval) throws -> NetworkReading {
        callCount += 1
        guard callCount >= 2 else {
            return .init(downBytesPerSec: nil, upBytesPerSec: nil, totalDown: 0, totalUp: 0)
        }
        return .init(downBytesPerSec: 1024, upBytesPerSec: 512, totalDown: 2048, totalUp: 1024)
    }
}

final class FakeDiskSampler: DiskSampling {
    var callCount = 0
    var lastRefreshMetadata: Bool?
    func sample(now: TimeInterval, refreshMetadata: Bool) throws -> DiskReading {
        callCount += 1
        lastRefreshMetadata = refreshMetadata
        return .init(readBytesPerSec: 0, writeBytesPerSec: 0, totalRead: 0, totalWritten: 0, freeSpace: nil, totalSpace: nil)
    }
}

final class FakeMemorySampler: MemorySampling {
    var callCount = 0
    func sample() throws -> MemoryReading {
        callCount += 1
        return .init(used: 0, total: 8_000_000_000, pressure: .normal)
    }
}

final class ScriptedMemorySampler: MemorySampling {
    private var results: [Result<MemoryReading, Error>]

    init(results: [Result<MemoryReading, Error>]) {
        self.results = results
    }

    func sample() throws -> MemoryReading {
        guard !results.isEmpty else {
            throw MetricSamplingError.systemCall("no more scripted memory results")
        }
        return try results.removeFirst().get()
    }
}

final class FakePowerSampler: PowerSampling {
    var callCount = 0
    func sample() throws -> PowerReading {
        callCount += 1
        return .init(
            isCharging: false,
            chargePercent: nil,
            batteryLevel: 0.5,
            cycleCount: nil,
            healthPercent: nil,
            timeRemaining: nil,
            batteryWatts: nil,
            adapterWatts: nil,
            adapterMaxWatts: nil,
            systemWatts: nil,
            externalConnected: false,
            hasBattery: false,
            batteryTemperature: nil
        )
    }
}

final class FakePeripheralBatterySampler: PeripheralBatterySampling {
    var callCount = 0
    func sample(now: TimeInterval) throws -> [PeripheralBatteryDevice] { callCount += 1; return [] }
}

final class FakeProcessUsageSampler: ProcessUsageSampling {
    private(set) var stoppedKinds: [ProcessMetricKind] = []
    func sample(_ kind: ProcessMetricKind, limit: Int) throws -> [ProcessUsage] { [.init(pid: 1, name: "test", value: 0.5)] }
    func stop(_ kind: ProcessMetricKind) { stoppedKinds.append(kind) }
}

final class CountingProcessUsageSampler: ProcessUsageSampling {
    private(set) var sampleCount = 0
    private(set) var stoppedKinds: [ProcessMetricKind] = []
    private let lock = NSLock()

    func sample(_ kind: ProcessMetricKind, limit: Int) throws -> [ProcessUsage] {
        lock.lock()
        sampleCount += 1
        lock.unlock()
        return [.init(pid: 1, name: "test", value: 0.5)]
    }

    func stop(_ kind: ProcessMetricKind) { stoppedKinds.append(kind) }
}

/// 记录 primeProcessBaselines 被调用的 kind 列表，验证启动预热。
final class RecordingProcessUsageSampler: ProcessUsageSampling {
    private(set) var sampleCount = 0
    private(set) var primedKinds: [ProcessMetricKind] = []
    private let lock = NSLock()

    func sample(_ kind: ProcessMetricKind, limit: Int) throws -> [ProcessUsage] {
        lock.lock(); sampleCount += 1; lock.unlock()
        return []
    }

    func stop(_ kind: ProcessMetricKind) {}

    func primeProcessBaselines(for kinds: [ProcessMetricKind]) {
        lock.lock(); primedKinds.append(contentsOf: kinds); lock.unlock()
    }

    var primedCount: Int { lock.lock(); defer { lock.unlock() }; return primedKinds.count }
}

/// 模拟 delta 指标未建立基线：首次返回空且 hasProcessBaseline=false。
final class PrimingProcessUsageSampler: ProcessUsageSampling {
    private(set) var sampleCount = 0
    private(set) var hasBaselineQueried = false

    func sample(_ kind: ProcessMetricKind, limit: Int) throws -> [ProcessUsage] {
        sampleCount += 1
        return []
    }
    func stop(_ kind: ProcessMetricKind) {}
    func hasProcessBaseline(for kind: ProcessMetricKind) -> Bool {
        hasBaselineQueried = true
        return false
    }
}

/// 模拟 delta 指标已有基线：返回空但 hasProcessBaseline=true（真无数据）。
final class BaselineReadyProcessUsageSampler: ProcessUsageSampling {
    private(set) var sampleCount = 0

    func sample(_ kind: ProcessMetricKind, limit: Int) throws -> [ProcessUsage] {
        sampleCount += 1
        return []
    }
    func stop(_ kind: ProcessMetricKind) {}
    func hasProcessBaseline(for kind: ProcessMetricKind) -> Bool { true }
}

/// 模拟 delta 指标首开：首采仅建基线返回空（此前无基线），此后基线就绪返回真实行。
/// 对齐真实 topGPU/topNetwork 的"首开必空"行为。
final class FirstEmptyThenRowsProcessUsageSampler: ProcessUsageSampling {
    private let lock = NSLock()
    private(set) var sampleCount = 0

    func sample(_ kind: ProcessMetricKind, limit: Int) throws -> [ProcessUsage] {
        lock.lock()
        sampleCount += 1
        let count = sampleCount
        lock.unlock()
        if count == 1 { return [] }
        return [
            ProcessUsage(pid: 1, name: "test", value: 0.5),
            ProcessUsage(pid: 2, name: "test2", value: 0.3),
        ]
    }

    func stop(_ kind: ProcessMetricKind) {}

    func hasProcessBaseline(for kind: ProcessMetricKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sampleCount >= 1
    }
}

/// 记录 sample / prime 执行时所在 dispatch 队列 label 的 fake 采样器。
/// 用于验证进程排行采样（nettop 子进程）不占用共享指标采样串行队列。
final class QueueRecordingProcessUsageSampler: ProcessUsageSampling {
    private let lock = NSLock()
    private var labels: [(call: String, label: String)] = []

    func sample(_ kind: ProcessMetricKind, limit: Int) throws -> [ProcessUsage] {
        record("sample")
        return [ProcessUsage(pid: 1, name: "test", value: 0.5)]
    }

    func stop(_ kind: ProcessMetricKind) {}

    func primeProcessBaselines(for kinds: [ProcessMetricKind]) {
        record("prime")
    }

    func hasProcessBaseline(for kind: ProcessMetricKind) -> Bool { true }

    private func record(_ call: String) {
        let label = String(cString: __dispatch_queue_get_label(nil))
        lock.lock()
        labels.append((call, label))
        lock.unlock()
    }

    /// 指定调用类型（"sample" / "prime"）记录到的队列 label 列表。
    func recordedLabels(for call: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return labels.filter { $0.call == call }.map(\.label)
    }

    var totalRecordedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return labels.count
    }
}

final class SequencedCPUSampler: CPUUsageSampling {
    var results: [Result<CPUUsageReading?, MetricSamplingError>]
    var index = 0

    init(results: [Result<CPUUsageReading?, MetricSamplingError>]) {
        self.results = results
    }

    func sample() throws -> CPUUsageReading? {
        defer { index += 1 }
        let result = results[min(index, results.count - 1)]
        return try result.get()
    }
}

// MARK: - Test Factory

@MainActor
private func makeManager(
    scheduler: RepeatingScheduling = FakeRepeatingScheduler(),
    samplers: FakeSamplerSet? = nil,
    cpu: CPUUsageSampling? = nil
) -> SystemMonitorManager {
    let s = samplers ?? FakeSamplerSet()
    return SystemMonitorManager(
        scheduler: scheduler,
        cpuSampler: cpu ?? s.cpu,
        gpuSampler: s.gpu,
        memorySampler: s.memory,
        temperatureSampler: s.temperature,
        networkSampler: s.network,
        diskSampler: s.disk,
        powerSampler: s.power,
        peripheralBatterySampler: s.peripheralBattery,
        processSampler: s.process
    )
}

final class FakeSamplerSet {
    let cpu = FakeCPUSampler()
    let gpu = FakeGPUSampler()
    let memory = FakeMemorySampler()
    let temperature = FakeTemperatureSampler()
    let network = FakeNetworkSampler()
    let disk = FakeDiskSampler()
    let power = FakePowerSampler()
    let peripheralBattery = FakePeripheralBatterySampler()
    let process = FakeProcessUsageSampler()
}

@MainActor
private func waitForSnapshot(
    _ manager: SystemMonitorManager,
    timeout: TimeInterval = 1.0,
    predicate: @escaping (SystemSnapshot) -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate(manager.snapshot) { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Timed out waiting for snapshot condition")
}

@MainActor
private func waitForCPUSampleCount(
    _ sampler: FakeCPUSampler,
    atLeast count: Int,
    timeout: TimeInterval = 1.0
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if sampler.callCount >= count { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Timed out waiting for CPU sample count >= \(count); got \(sampler.callCount)")
}

@MainActor
private func waitForProcessSampleCount(
    _ sampler: CountingProcessUsageSampler,
    atLeast count: Int,
    timeout: TimeInterval = 1.0
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if sampler.sampleCount >= count { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Timed out waiting for process sample count >= \(count); got \(sampler.sampleCount)")
}

@MainActor
private func waitForPrimeCount(
    _ sampler: RecordingProcessUsageSampler,
    atLeast count: Int,
    timeout: TimeInterval = 1.0
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if sampler.primedCount >= count { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Timed out waiting for prime count >= \(count); got \(sampler.primedCount)")
}

@MainActor
private func waitForProcessState(
    _ manager: SystemMonitorManager,
    timeout: TimeInterval = 1.0,
    predicate: @escaping (ProcessBreakdownState) -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate(manager.processState) { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Timed out waiting for process state condition; last state: \(manager.processState)")
}

@MainActor
private func waitForPrimingSampleCount(
    _ sampler: PrimingProcessUsageSampler,
    atLeast count: Int,
    timeout: TimeInterval = 1.0
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if sampler.sampleCount >= count { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Timed out waiting for priming sample count >= \(count); got \(sampler.sampleCount)")
}

@MainActor
private func waitForFirstEmptySampleCount(
    _ sampler: FirstEmptyThenRowsProcessUsageSampler,
    atLeast count: Int,
    timeout: TimeInterval = 1.0
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if sampler.sampleCount >= count { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Timed out waiting for process sample count >= \(count); got \(sampler.sampleCount)")
}


@MainActor
private func waitForQueueRecordedCalls(
    _ sampler: QueueRecordingProcessUsageSampler,
    atLeast count: Int,
    timeout: TimeInterval = 2.0
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if sampler.totalRecordedCount >= count { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Timed out waiting for recorded process sampler calls >= \(count); got \(sampler.totalRecordedCount)")
}

/// 慢 CPU 采样器：模拟真实 GPU/proc 采样耗时，阻塞串行采样队列。
final class SlowTestCPUSampler: CPUUsageSampling {
    let delay: TimeInterval
    init(delay: TimeInterval) { self.delay = delay }

    func sample() throws -> CPUUsageReading? {
        Thread.sleep(forTimeInterval: delay)
        return CPUUsageReading(total: 0.5, user: 0.3, system: 0.2)
    }
}
