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

    func test_stopSamplingClearsSnapshot() {
        let manager = makeManager()
        manager.setPanelDemand(.init(system: true, cpu: true))
        XCTAssertTrue(manager.isSampling)
        manager.setPanelDemand(.none)
        XCTAssertFalse(manager.isSampling)
        XCTAssertNil(manager.snapshot.sampledAt)
        XCTAssertTrue(manager.snapshot.issues.isEmpty)
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

    func test_stopSamplingResetsHistory() async throws {
        let manager = makeManager()
        manager.setPanelDemand(.init(system: true, cpu: true))
        try await waitForSnapshot(manager) { $0.cpuUsage != nil }
        XCTAssertFalse(manager.history.cpu.isEmpty)
        manager.setPanelDemand(.none)
        XCTAssertTrue(manager.history.cpu.isEmpty)
        XCTAssertTrue(manager.history.gpu.isEmpty)
    }

    func test_menuBarMetricsDriveSampling() {
        let manager = makeManager()
        XCTAssertFalse(manager.isSampling)
        manager.setMenuBarMetrics([.cpu])
        XCTAssertTrue(manager.isSampling)
        manager.setMenuBarMetrics([])
        XCTAssertFalse(manager.isSampling)
    }

    func test_alertRequirementsDriveSampling() {
        let manager = makeManager()
        XCTAssertFalse(manager.isSampling)
        manager.setAlertRequirements([.cpu])
        XCTAssertTrue(manager.isSampling)
        manager.setAlertRequirements([])
        XCTAssertFalse(manager.isSampling)
    }

    func test_setAlertRequirementsAloneStartsSampling() {
        let scheduler = FakeRepeatingScheduler()
        let manager = makeManager(scheduler: scheduler)
        XCTAssertFalse(manager.isSampling)

        manager.setAlertRequirements([.cpu])
        XCTAssertTrue(manager.isSampling)
        XCTAssertEqual(scheduler.activeScheduleCount, 1)

        manager.setAlertRequirements([])
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

        // 仅菜单栏（无面板 demand）：disk 后台 stride=5，需推进 tick 才会采样
        manager.setPanelDemand(.none)
        disk.callCount = 0
        disk.lastRefreshMetadata = nil
        manager.setMenuBarMetrics([.disk])
        // startSampling 的即时 sampleAll 在 tick=1 时通常不采样 disk；再 fire 到 stride 倍数
        for _ in 0..<8 {
            if disk.callCount >= 1 { break }
            scheduler.fire()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await waitForSnapshot(manager) { _ in disk.callCount >= 1 }
        XCTAssertEqual(disk.lastRefreshMetadata, false)
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
        // 等待采样真正执行完成（hasBaselineQueried 在 sample 返回空后才被查询）。
        try await waitForBaselineQuery(process)
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
private func waitForBaselineQuery(
    _ sampler: PrimingProcessUsageSampler,
    timeout: TimeInterval = 1.0
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if sampler.hasBaselineQueried { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Timed out waiting for hasProcessBaseline query")
}
