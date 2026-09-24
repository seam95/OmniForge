import Foundation
import Combine

/// 系统监控运行时 — 按需驱动采样，面板关闭且无菜单栏/告警需求时零开销
@MainActor
final class SystemMonitorManager: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot()
    /// 面板趋势折线历史（仅前台采样时追加）
    @Published private(set) var history = MetricHistory()
    @Published private(set) var processState = ProcessBreakdownState.collapsed
    @Published private(set) var isSampling = false
    @Published private(set) var speedTestState: SpeedTestState = .idle

    private let scheduler: RepeatingScheduling
    private let queue = DispatchQueue(label: "com.omniforge.system-monitor", qos: .utility)
    private var cancellables = Set<AnyCancellable>()
    /// 测速状态订阅，独立于采样 scheduler，避免 stopSampling 清掉
    private var speedTestCancellable: AnyCancellable?
    private var demand = MonitorDemand.none
    /// 停止采样令牌：stopSampling 时自增，使在途采样的主线程回写失效。
    private var generation = 0
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
    /// 指标连续强制采样（无视后台 stride）的次数；拿到读数即清零，启停采样时整体清空。
    private var forcedSampleAttempts: [MonitorMetric: Int] = [:]
    /// 进程 Top 列表节流：对齐 Vorssaint，展开后最短 4s 刷新一次
    private var lastProcessSampleAt: Date?
    /// 仅用于成功 GPU 读数的平滑基线；失败不沿用旧值
    private var lastGPUUsage: Double?
    /// 面板打开后的短间隔追加采样（可取消）；关闭面板即作废
    private var rapidFollowUp: DispatchWorkItem?
    /// 进程排行首开补采任务（可取消）；收起/切换指标/停采样即作废
    private var processFollowUp: DispatchWorkItem?
    /// 当前展开指标的补采已调度次数（基线始终建不起来时封顶，防无限重试）
    private var processFollowUpAttempts = 0
    private static let rapidFollowUpDelay: TimeInterval = 0.5
    /// delta 类指标首开补采间隔：首采仅建基线，1s 后补采即可算出真实速率
    private static let processFollowUpDelay: TimeInterval = 1.0
    private static let processFollowUpMaxAttempts = 4
    /// 缺读数指标连续强制采样的上限（约 3 个基础 tick 的宽容期）：封顶后交回 stride，
    /// 防止「采样器长期无数据」把后台降频永久击穿为每 tick 全采。
    private static let maxForcedInitialSamples = 3
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
        let wasPanelOpen = self.demand != .none
        self.demand = demand
        let samplingStarted = updateSampling()
        // 采样器可能因菜单栏/告警需求早已运行，此时 startSampling 的即时采样不会触发，
        // 面板新需求的指标（GPU/磁盘/网络等）要干等下一个 refreshInterval tick——
        // 在面板打开边沿补一轮立即采样，让面板打开即出数。
        if !wasPanelOpen, demand != .none, !samplingStarted {
            sampleAll(appendsHistory: false)
            scheduleRapidFollowUp()
        }
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
        processFollowUp?.cancel()
        processFollowUp = nil
        processFollowUpAttempts = 0
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

    /// 返回值：本次调用是否执行了 startSampling（供补采分支避免双重立即采样）
    @discardableResult
    private func updateSampling() -> Bool {
        let shouldBeActive = demand != .none
            || !menuBarMetrics.isEmpty
            || !alertRequirements.isEmpty
        if shouldBeActive && !isSampling {
            startSampling()
            return true
        } else if !shouldBeActive && isSampling {
            stopSampling()
        }
        return false
    }

    private func startSampling() {
        isSampling = true
        tickCount = 0
        forcedSampleAttempts = [:]
        // 进入面板时先立即采样，避免等一个完整 refreshInterval 才看到指标
        sampleAll()
        // 异步预热 GPU/网络 delta 基线，使首次展开排行直接出数据而非先返回空。
        primeProcessBaselines()
        scheduleRapidFollowUp()
        scheduler.schedule(every: refreshInterval, { [weak self] in self?.sampleAll() })
            .store(in: &cancellables)
    }

    /// 面板打开后或菜单栏网速待建基线时 ~0.5s 的追加采样：delta 类指标（网速/磁盘速率）首轮只建基线，
    /// 短间隔补一轮即可出速率，无需等完整 refreshInterval；关闭面板或无网速需求即作废。
    private func scheduleRapidFollowUp() {
        rapidFollowUp?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isSampling else { return }
            let needsFollowUp = self.demand != .none
                || (self.menuBarMetrics.contains(.network) && self.snapshot.netDownBytesPerSec == nil)
            guard needsFollowUp else { return }
            self.sampleAll(appendsHistory: false)
        }
        rapidFollowUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rapidFollowUpDelay, execute: work)
    }

    /// 后台预热 delta 类指标基线（GPU/网络）。仅建基线，不触发 UI 状态变更。
    private func primeProcessBaselines() {
        queue.async { [weak self] in
            self?.processSampler.primeProcessBaselines(for: [.gpu, .network])
        }
    }

    private func stopSampling() {
        isSampling = false
        rapidFollowUp?.cancel()
        rapidFollowUp = nil
        processFollowUp?.cancel()
        processFollowUp = nil
        cancellables.removeAll()
        stopActiveProcessSamplerIfNeeded()
        processState = .collapsed
        lastProcessSampleAt = nil
        // SPEC §9.1.2/§9.1.3：停止路径不得在主线程等待采样队列。lastGPUUsage 只在
        // 采样队列读写，清理放回队列异步执行；generation 令牌使在途采样的
        // 主线程回写失效（晚到结果不覆盖停止后的状态）。
        generation &+= 1
        queue.async { [weak self] in
            self?.lastGPUUsage = nil
        }
        // SPEC §9.1.4：普通停止/页面切换保留最近 snapshot 与 history（下次打开
        // 立即有内容可显示，新采样到达后覆盖）；功能卸载时随 manager 释放。
        tickCount = 0
        forcedSampleAttempts = [:]
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
            case .battery: metrics.insert(.power)
            case .cpuTemperature: metrics.insert(.cpuTemperature)
            case .gpuTemperature: metrics.insert(.gpuTemperature)
            case .batteryTemperature: metrics.insert(.batteryTemperature)
            case .peripheralBattery: metrics.insert(.peripheralBattery)
            }
        }

        metrics.formUnion(alertRequirements)
        return metrics
    }

    /// - Parameter appendsHistory: 是否追加趋势历史。定时 tick 与 startSampling 即时轮追加；
    ///   面板打开的补采轮与 rapidFollowUp 属非定时点，追加会破坏折线等距 x 轴，传 false。
    private func sampleAll(appendsHistory: Bool = true) {
        tickCount += 1
        let needed = neededMetrics()
        let isForeground = demand != .none
        let previousSnapshot = snapshot
        let now = Date()
        // 捕获当次 generation：停止采样（generation 变化）后，在途结果回写被丢弃。
        let capturedGeneration = generation
        // 强制采样集合在主线程判定（只读上一轮快照 + 会话内计数），采样队列只消费结果，
        // 避免把 @MainActor 状态丢进后台队列读写。
        let forced = forcedMetrics(in: needed, previous: previousSnapshot, isFirstTick: tickCount == 1)

        queue.async { [weak self] in
            guard let self else { return }
            var newSnapshot = previousSnapshot // 携带上一轮值，仅被采样的指标会覆盖
            newSnapshot.sampledAt = now
            newSnapshot.issues = [:] // 清空上一轮问题记录

            for metric in needed {
                let stride = self.policy.backgroundTickStride(for: metric)
                // 前台面板每 tick 全采；后台由 forced（启动首轮/缺读数，已封顶）与
                // stride 共同决定。
                let shouldSample = isForeground || forced.contains(metric) || self.tickCount % stride == 0
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
                // 停止采样（generation 已换）后到达的旧轮结果直接丢弃。
                guard self.generation == capturedGeneration else { return }
                self.snapshot = newSnapshot
                // 仅前台（面板可见）追加历史，保证等距 x 轴；后台降频采样与
                // 面板打开补采（非定时点）不追加。
                if isForeground && appendsHistory {
                    self.history.append(newSnapshot)
                }
                // 展开态下随 sampleAll 刷新进程列表（4s 节流，仅前台面板）
                self.refreshProcessUsageIfNeeded(isForeground: isForeground)
            }
        }
    }

    /// 本轮应无视后台 stride 强制采样的指标。
    ///
    /// 两种来源：
    /// - 首轮（`isFirstTick`）：停止采样会保留上一份 snapshot，重启时读数可能全部
    ///   存在，但仍要立即刷新一遍，否则要等 stride 对齐（GPU 10s / 温度 16s）。
    /// - 指标尚无读数：会话中途新启用的指标（用户在设置里勾选 GPU/温度）下一个 tick
    ///   就要出数，不能干等 stride。
    ///
    /// 后者按指标封顶（`maxForcedInitialSamples`）：采样器可能长期返回「无数据」而不
    /// 抛错（无温度 HID 通道、无 GPU 利用率、无外设电量），无限强制采样会把后台降频
    /// 永久改成每 tick 全采——那正是降频要避免的开销。
    private func forcedMetrics(
        in needed: Set<MonitorMetric>,
        previous: SystemSnapshot,
        isFirstTick: Bool
    ) -> Set<MonitorMetric> {
        if isFirstTick { return needed }

        // 只保留当前需要指标的预算：指标被停用后重新启用应重新获得宽容期
        // （否则重新勾选一个"无数据"指标时要干等一整个 stride）。
        forcedSampleAttempts = forcedSampleAttempts.filter { needed.contains($0.key) }

        var forced: Set<MonitorMetric> = []
        for metric in needed {
            if !Self.isMetricMissingInitialReading(metric, in: previous) {
                // 有读数即重置预算：读数丢失（如网速重建基线）时重新获得宽容期。
                forcedSampleAttempts[metric] = 0
                continue
            }
            let attempts = forcedSampleAttempts[metric] ?? 0
            guard attempts < Self.maxForcedInitialSamples else { continue }
            forcedSampleAttempts[metric] = attempts + 1
            forced.insert(metric)
        }
        return forced
    }

    /// 判定指标在上一轮快照中是否尚无有效读数且无错误（新启用或启动初值缺失）。
    /// 纯函数：只在主线程调用，供 `forcedMetrics` 判定。
    private static func isMetricMissingInitialReading(
        _ metric: MonitorMetric,
        in snapshot: SystemSnapshot
    ) -> Bool {
        switch metric {
        case .cpu:
            return snapshot.cpuUsage == nil && snapshot.issues[.cpu] == nil
        case .gpu:
            return snapshot.gpuUsage == nil && snapshot.issues[.gpu] == nil
        case .memory:
            return snapshot.memoryUsed == nil && snapshot.issues[.memory] == nil
        case .network:
            return snapshot.netDownBytesPerSec == nil && snapshot.issues[.network] == nil
        case .disk:
            return snapshot.disk == nil && snapshot.issues[.disk] == nil
        case .power:
            return snapshot.power == nil && snapshot.issues[.power] == nil
        case .cpuTemperature:
            return snapshot.cpuTemperature == nil && snapshot.issues[.cpuTemperature] == nil
        case .gpuTemperature:
            return snapshot.gpuTemperature == nil && snapshot.issues[.gpuTemperature] == nil
        case .batteryTemperature:
            return snapshot.batteryTemperature == nil && snapshot.issues[.batteryTemperature] == nil
        case .peripheralBattery:
            // 空数组即「无读数」：本机没有外设电池时该指标永远采不到设备，
            // 与温度返回 nil 同理，交给封顶逻辑兜底，不做特殊豁免。
            return snapshot.peripheralBatteries.isEmpty && snapshot.issues[.peripheralBattery] == nil
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
        // 采样前记录基线状态：delta 类指标（GPU/网络）首采仅建基线、必返回空。
        // 据此识别"首开刚建基线"场景并调度短间隔补采，避免空态干等 4s 节流 tick。
        let hadBaseline = processSampler.hasProcessBaseline(for: kind)
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
                    // 首开仅建基线（采样前无基线）或基线未就绪：保持 loading 并
                    // ~1s 后补采；补采次数封顶，超限落 loaded 防止无限重试。
                    let stillPriming = rows.isEmpty && (!hadBaseline || needsBaseline)
                    if stillPriming, self.processFollowUpAttempts < Self.processFollowUpMaxAttempts {
                        self.processState = .loading(kind)
                        self.scheduleProcessFollowUp(kind)
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

    /// 首开/基线未就绪时的短间隔补采：直接调 sampleProcessUsage 绕过 4s 节流；
    /// 收起/切换指标由 setExpandedProcessMetric 取消，work 内的 kind 守卫兜底。
    private func scheduleProcessFollowUp(_ kind: ProcessMetricKind) {
        processFollowUpAttempts += 1
        processFollowUp?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.processState.kind == kind else { return }
            self.sampleProcessUsage(kind)
        }
        processFollowUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.processFollowUpDelay, execute: work)
    }
}
