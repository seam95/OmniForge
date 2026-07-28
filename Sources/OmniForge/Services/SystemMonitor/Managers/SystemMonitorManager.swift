import Foundation
import Combine

/// 系统监控运行时 — 按需驱动采样，面板关闭且无菜单栏/告警需求时零开销
@MainActor
final class SystemMonitorManager: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot()
    @Published private(set) var processState = ProcessBreakdownState.collapsed
    @Published private(set) var isSampling = false
    @Published private(set) var speedTestState: SpeedTestState = .idle

    private let scheduler: RepeatingScheduling
    private let queue = DispatchQueue(label: "com.omniforge.system-monitor", qos: .utility)
    private var cancellables = Set<AnyCancellable>()
    /// 测速状态订阅，独立于采样 scheduler，避免 stopSampling 清掉
    private var speedTestCancellable: AnyCancellable?
    private var demand = MonitorDemand.none
    private var menuBarMetrics = Set<MenuBarMetric>()
    private var alertRequirements = Set<MonitorMetric>()
    private var refreshInterval: TimeInterval = 2.0

    /// 测试可观察：当前菜单栏采样需求
    var activeMenuBarMetrics: Set<MenuBarMetric> { menuBarMetrics }
    /// 测试可观察：当前告警采样需求
    var activeAlertRequirements: Set<MonitorMetric> { alertRequirements }
    /// 测试可观察：当前刷新间隔（秒）
    var activeRefreshInterval: TimeInterval { refreshInterval }
    private var policy = MonitorSamplingPolicy(baseTick: 2)
    private var tickCount = 0
    /// 进程 Top 列表节流：对齐 Vorssaint，展开后最短 4s 刷新一次
    private var lastProcessSampleAt: Date?
    /// 仅用于成功 GPU 读数的平滑基线；失败不沿用旧值
    private var lastGPUUsage: Double?
    private static let processRefreshInterval: TimeInterval = 4.0
    private static let processDisplayLimit = ProcessRankingDisplay.limit

    private let cpuSampler: CPUUsageSampling
    private let gpuSampler: GPUUsageSampling
    private let memorySampler: MemorySampling
    private let temperatureSampler: TemperatureSampling
    private let networkSampler: NetworkSampling
    private let diskSampler: DiskSampling
    private let powerSampler: PowerSampling
    private let peripheralBatterySampler: PeripheralBatterySampling
    private let processSampler: ProcessUsageSampling
    private let speedTest: SpeedTest

    init(
        scheduler: RepeatingScheduling,
        cpuSampler: CPUUsageSampling,
        gpuSampler: GPUUsageSampling,
        memorySampler: MemorySampling,
        temperatureSampler: TemperatureSampling,
        networkSampler: NetworkSampling,
        diskSampler: DiskSampling,
        powerSampler: PowerSampling,
        peripheralBatterySampler: PeripheralBatterySampling,
        processSampler: ProcessUsageSampling,
        speedTest: SpeedTest = SpeedTest()
    ) {
        self.scheduler = scheduler
        self.cpuSampler = cpuSampler
        self.gpuSampler = gpuSampler
        self.memorySampler = memorySampler
        self.temperatureSampler = temperatureSampler
        self.networkSampler = networkSampler
        self.diskSampler = diskSampler
        self.powerSampler = powerSampler
        self.peripheralBatterySampler = peripheralBatterySampler
        self.processSampler = processSampler
        self.speedTest = speedTest
        speedTestCancellable = speedTest.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.speedTestState = state
            }
    }

    /// 触发网速测试（下载测速）
    func startSpeedTest() {
        speedTest.start()
    }

    func setPanelDemand(_ demand: MonitorDemand) {
        self.demand = demand
        updateSampling()
    }

    func setMenuBarMetrics(_ metrics: Set<MenuBarMetric>) {
        menuBarMetrics = metrics
        updateSampling()
    }

    func setAlertRequirements(_ requirements: Set<MonitorMetric>) {
        alertRequirements = requirements
        updateSampling()
    }

    func setExpandedProcessMetric(_ kind: ProcessMetricKind?) {
        if let current = processState.kind, current != kind {
            processSampler.stop(current)
        }
        guard let kind else {
            processState = .collapsed
            lastProcessSampleAt = nil
            return
        }
        processState = .loading(kind)
        lastProcessSampleAt = nil
        sampleProcessUsage(kind)
    }

    /// 折叠/停采样时清理进程采样器内部状态（如 network delta baseline）
    private func stopActiveProcessSamplerIfNeeded() {
        if let kind = processState.kind {
            processSampler.stop(kind)
        }
    }

    func setInterval(seconds: Int) throws {
        guard [1, 2, 5].contains(seconds) else {
            throw MonitorPreferenceError.invalidRefreshInterval(seconds)
        }
        let newInterval = TimeInterval(seconds)
        guard newInterval != refreshInterval else { return }
        refreshInterval = newInterval
        policy = MonitorSamplingPolicy(baseTick: seconds)
        if isSampling {
            stopSampling()
            startSampling()
        }
    }

    /// Immediate metrics refresh. When `forceProcess` is true and a process kind is expanded,
    /// re-sample that ranking even if the 4s process throttle has not elapsed.
    func refreshNow(forceProcess: Bool = false) {
        sampleAll()
        if forceProcess {
            forceRefreshProcessUsageIfNeeded()
        }
    }

    // MARK: - 内部采样

    private func updateSampling() {
        let shouldBeActive = demand != .none
            || !menuBarMetrics.isEmpty
            || !alertRequirements.isEmpty
        if shouldBeActive && !isSampling {
            startSampling()
        } else if !shouldBeActive && isSampling {
            stopSampling()
        }
    }

    private func startSampling() {
        isSampling = true
        tickCount = 0
        // 进入面板时先立即采样，避免等一个完整 refreshInterval 才看到指标
        sampleAll()
        // 异步预热 GPU/网络 delta 基线，使首次展开排行直接出数据而非先返回空。
        primeProcessBaselines()
        scheduler.schedule(every: refreshInterval, { [weak self] in self?.sampleAll() })
            .store(in: &cancellables)
    }

    /// 后台预热 delta 类指标基线（GPU/网络）。仅建基线，不触发 UI 状态变更。
    private func primeProcessBaselines() {
        queue.async { [weak self] in
            self?.processSampler.primeProcessBaselines(for: [.gpu, .network])
        }
    }

    private func stopSampling() {
        isSampling = false
        cancellables.removeAll()
        stopActiveProcessSamplerIfNeeded()
        processState = .collapsed
        lastProcessSampleAt = nil
        // lastGPUUsage is only read/written on the sample queue; clear there to avoid
        // a main-vs-utility race with in-flight sampleAll blocks.
        queue.sync { lastGPUUsage = nil }
        snapshot = SystemSnapshot()
        tickCount = 0
    }

    /// 当前需要采集的全部指标（面板 + 菜单栏 + 告警）
    private func neededMetrics() -> Set<MonitorMetric> {
        var metrics = Set<MonitorMetric>()

        if demand.system || demand.cpu { metrics.insert(.cpu) }
        if demand.system || demand.gpu { metrics.insert(.gpu) }
        if demand.system || demand.memory { metrics.insert(.memory) }
        if demand.network { metrics.insert(.network) }
        if demand.disk { metrics.insert(.disk) }
        if demand.power || demand.battery { metrics.insert(.power) }
        if demand.cpuTemperature || demand.system { metrics.insert(.cpuTemperature) }
        if demand.gpuTemperature || demand.system { metrics.insert(.gpuTemperature) }
        if demand.batteryTemperature || demand.system { metrics.insert(.batteryTemperature) }
        if demand.peripheralBattery { metrics.insert(.peripheralBattery) }

        for metric in menuBarMetrics {
            switch metric {
            case .cpu: metrics.insert(.cpu)
            case .gpu: metrics.insert(.gpu)
            case .memory: metrics.insert(.memory)
            case .network: metrics.insert(.network)
            case .disk: metrics.insert(.disk)
            case .power, .battery: metrics.insert(.power)
            case .cpuTemperature: metrics.insert(.cpuTemperature)
            case .gpuTemperature: metrics.insert(.gpuTemperature)
            case .batteryTemperature: metrics.insert(.batteryTemperature)
            case .peripheralBattery: metrics.insert(.peripheralBattery)
            case .date: break
            }
        }

        metrics.formUnion(alertRequirements)
        return metrics
    }

    private func sampleAll() {
        tickCount += 1
        let needed = neededMetrics()
        let isForeground = demand != .none
        let previousSnapshot = snapshot
        let now = Date()

        queue.async { [weak self] in
            guard let self else { return }
            var newSnapshot = previousSnapshot // 携带上一轮值，仅被采样的指标会覆盖
            newSnapshot.sampledAt = now
            newSnapshot.issues = [:] // 清空上一轮问题记录

            for metric in needed {
                let shouldSample: Bool
                if isForeground {
                    shouldSample = true
                } else {
                    let stride = self.policy.backgroundTickStride(for: metric)
                    shouldSample = self.tickCount % stride == 0
                }
                guard shouldSample else { continue }

                switch metric {
                case .cpu:
                    do { newSnapshot.cpuUsage = try self.cpuSampler.sample() }
                    catch {
                        newSnapshot.cpuUsage = nil
                        newSnapshot.issues[.cpu] = .failed("\(error)")
                    }
                case .gpu:
                    do {
                        let raw = try self.gpuSampler.sample()
                        if let raw {
                            let stabilized = MetricFormat.stabilizedGPUUsage(
                                previous: self.lastGPUUsage,
                                current: raw
                            )
                            self.lastGPUUsage = stabilized
                            newSnapshot.gpuUsage = stabilized
                        } else {
                            // 成功但无读数：清空展示，不沿用旧值；保留平滑基线供下次成功读数
                            newSnapshot.gpuUsage = nil
                        }
                    } catch {
                        newSnapshot.gpuUsage = nil
                        newSnapshot.issues[.gpu] = .failed("\(error)")
                    }
                case .memory:
                    do {
                        let mem = try self.memorySampler.sample()
                        newSnapshot.memoryUsed = mem.used
                        newSnapshot.memoryTotal = mem.total
                        newSnapshot.memoryPressure = mem.pressure
                    } catch {
                        newSnapshot.memoryUsed = nil
                        newSnapshot.memoryTotal = nil
                        // Do not keep a prior pressure level after a failed sample.
                        newSnapshot.memoryPressure = .unknown
                        newSnapshot.issues[.memory] = .failed("\(error)")
                    }
                case .cpuTemperature:
                    do {
                        newSnapshot.cpuTemperature = try self.temperatureSampler.sampleCPU()
                    } catch {
                        newSnapshot.cpuTemperature = nil
                        newSnapshot.issues[.cpuTemperature] = .failed("\(error)")
                    }
                case .gpuTemperature:
                    do {
                        newSnapshot.gpuTemperature = try self.temperatureSampler.sampleGPU()
                    } catch {
                        newSnapshot.gpuTemperature = nil
                        newSnapshot.issues[.gpuTemperature] = .failed("\(error)")
                    }
                case .batteryTemperature:
                    do {
                        newSnapshot.batteryTemperature = try self.temperatureSampler.sampleBattery()
                    } catch {
                        newSnapshot.batteryTemperature = nil
                        newSnapshot.issues[.batteryTemperature] = .failed("\(error)")
                    }
                case .network:
                    do {
                        let net = try self.networkSampler.sample(now: now.timeIntervalSince1970)
                        newSnapshot.netDownBytesPerSec = net.downBytesPerSec
                        newSnapshot.netUpBytesPerSec = net.upBytesPerSec
                        newSnapshot.netTotalDown = net.totalDown
                        newSnapshot.netTotalUp = net.totalUp
                    } catch {
                        newSnapshot.netDownBytesPerSec = nil
                        newSnapshot.netUpBytesPerSec = nil
                        newSnapshot.issues[.network] = .failed("\(error)")
                    }
                case .disk:
                    do {
                        let disk = try self.diskSampler.sample(
                            now: now.timeIntervalSince1970,
                            refreshMetadata: isForeground
                        )
                        newSnapshot.disk = disk
                    } catch {
                        newSnapshot.disk = nil
                        newSnapshot.issues[.disk] = .failed("\(error)")
                    }
                case .power:
                    do { newSnapshot.power = try self.powerSampler.sample() }
                    catch {
                        newSnapshot.power = nil
                        newSnapshot.issues[.power] = .failed("\(error)")
                    }
                case .peripheralBattery:
                    do {
                        newSnapshot.peripheralBatteries = try self.peripheralBatterySampler.sample(now: now.timeIntervalSince1970)
                    } catch {
                        newSnapshot.peripheralBatteries = []
                        newSnapshot.issues[.peripheralBattery] = .failed("\(error)")
                    }
                }
            }

            DispatchQueue.main.async {
                self.snapshot = newSnapshot
                // 展开态下随 sampleAll 刷新进程列表（4s 节流，仅前台面板）
                self.refreshProcessUsageIfNeeded(isForeground: isForeground)
            }
        }
    }

    /// 若已展开且距上次采样 ≥ 4s，则重新采样 Top 进程
    private func refreshProcessUsageIfNeeded(isForeground: Bool) {
        guard isForeground, let kind = processState.kind else { return }
        // loading 中不重复触发，避免并发覆盖
        if case .loading = processState { return }
        if let last = lastProcessSampleAt,
           Date().timeIntervalSince(last) < Self.processRefreshInterval {
            return
        }
        sampleProcessUsage(kind)
    }

    /// Ranking "Refresh All": bypass process throttle while a kind is expanded.
    private func forceRefreshProcessUsageIfNeeded() {
        guard let kind = processState.kind else { return }
        if case .loading = processState { return }
        sampleProcessUsage(kind)
    }

    private func sampleProcessUsage(_ kind: ProcessMetricKind) {
        lastProcessSampleAt = Date()
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let rows = try self.processSampler.sample(kind, limit: Self.processDisplayLimit)
                // 空返回 + 未建立基线 => 仍在预热，保持 loading 而非误显 empty。
                // 有基线仍空才视为真无数据（切 .loaded 由 UI 显示 empty）。
                let needsBaseline = rows.isEmpty && !self.processSampler.hasProcessBaseline(for: kind)
                DispatchQueue.main.async {
                    // 若期间已折叠或切换到其他指标，丢弃过期结果
                    guard self.processState.kind == kind else { return }
                    if needsBaseline {
                        self.processState = .loading(kind)
                    } else {
                        self.processState = .loaded(kind, rows)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.processState.kind == kind else { return }
                    self.processState = .failed(kind, "\(error)")
                }
            }
        }
    }
}
