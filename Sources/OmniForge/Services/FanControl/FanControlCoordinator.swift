import Foundation
import Combine
import AppKit

/// Helper 命令边界 — FanHelperClient 实现生产路径，测试注入替身记录命令
protocol FanHelperCommanding: AnyObject {
    func setFanSpeed(index: Int, rpm: Int, completion: @escaping (Bool, String?) -> Void)
    func setFanAuto(index: Int, completion: @escaping (Bool, String?) -> Void)
    func resetAllFans(completion: @escaping (Bool, String?) -> Void)
    func fetchVersion(completion: @escaping (String?) -> Void)
}

extension FanHelperClient: FanHelperCommanding {}

/// 风扇控制协调器 — 订阅监控快照驱动性能模式曲线下发，管理手动覆盖与系统事件归还。
///
/// 归还语义（SPEC §4.5）：性能模式关闭/被电池省电抑制/系统睡眠/屏幕锁（未开保持
/// 开关）时，经 resetAllFans 全量归还自动模式 — 这是唯一归还路径，归还后清空
/// 全部内部状态（平滑缓存/上次下发/手动目标）。
@MainActor
final class FanControlCoordinator: ObservableObject {
    /// 性能模式当前请求的目标转速百分比（0-100，UI 展示用）
    @Published private(set) var performanceCurvePercent: Double = 0
    /// 电池省电正在抑制性能模式
    @Published private(set) var batterySaverSuppressed = false
    /// 上次命令错误（下发失败提示）
    @Published private(set) var lastError: String?
    /// 机器是否有风扇 — nil=尚无快照；false=无风扇机型（设置页隐藏控制入口）
    @Published private(set) var hasFans: Bool?
    /// Helper 注册状态缓存 — SMAppService.status 是同步 XPC（实测 ~120ms），
    /// 绝不可进每 2s 的快照评估路径（会冻结主 runloop 上的全局事件 tap）。
    /// 启动时同步解析一次，此后仅事件驱动刷新（安装/卸载/页面进入）。
    @Published private(set) var helperRegistered = false
    /// 后台刷新防重入
    private var refreshInFlight = false

    private let helper: FanHelperCommanding
    private let powerSupply: PowerSupplyChecking
    /// Helper 注册状态边界 — 生产查 SMAppService，测试注入固定值
    private let isHelperRegistered: () -> Bool
    private var preferences: FanPreferences?
    private var monitor: SystemMonitorManager?
    private var monitorPreferences: MonitorPreferences?
    private var cancellables = Set<AnyCancellable>()

    private var smoothedZoneTemps: [ThermalZone: Double] = [:]
    private var lastSentRPM: [Int: Double] = [:]
    /// 手动覆盖目标（风扇序号 → RPM）；手动风扇不参与曲线计算
    private var manualTargets: [Int: Double] = [:]
    private var wasPerformanceActive = false
    private var systemAsleep = false
    /// 挂起原因集合（屏幕睡眠 / 锁屏各自独立登记与解除，
    /// 避免一个 wake 事件错误解除另一原因仍有效的挂起）。
    private var suspensionReasons: Set<SuspensionReason> = []
    /// 监控总开关关闭/特性卸载导致的挂起（独立于屏幕睡眠/锁屏挂起）
    private var monitoringSuspended = false
    /// 归还事务进行中：串行化，晚到的速度命令不得覆盖 reset
    private var resetInFlight = false
    /// 归还失败待恢复：置位后 evaluate 优先重试归还而非下发曲线
    private var resetRecoveryPending = false
    /// 应用退出事务已启动：禁止一切新的下发
    private var quitting = false
    private var observersInstalled = false

    enum SuspensionReason: Hashable {
        case screenAsleep
        case screenLocked
    }

    init(
        helper: FanHelperCommanding,
        powerSupply: PowerSupplyChecking,
        isHelperRegistered: @escaping () -> Bool = { FanHelperInstaller.isRegistered() }
    ) {
        self.helper = helper
        self.powerSupply = powerSupply
        self.isHelperRegistered = isHelperRegistered
    }

    // MARK: - 接线

    /// 订阅监控快照与偏好变化；在 FeatureFactory 装配时调用一次。
    /// - Parameter immediatelyResolveRegistration: true 时同步解析 Helper 注册状态
    ///   （测试用，注入闭包零开销）；生产传 false — 后台解析，避免把同步 XPC
    ///   （实测 ~120ms）带进 app 启动路径。缓存就绪前 evaluate 跳过下发，
    ///   就绪后下一轮快照自动接管。
    func start(
        monitor: SystemMonitorManager,
        preferences: FanPreferences,
        monitorPreferences: MonitorPreferences,
        immediatelyResolveRegistration: Bool = true
    ) {
        self.monitor = monitor
        self.preferences = preferences
        self.monitorPreferences = monitorPreferences
        if immediatelyResolveRegistration {
            helperRegistered = isHelperRegistered()
        } else {
            refreshHelperRegistration()
        }
        setupSystemObserversIfNeeded()

        monitor.$snapshot
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.evaluate(snapshot: snapshot)
            }
            .store(in: &cancellables)

        preferences.$configuration
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // 偏好转关/转开的即时响应：用最新快照重评估
                if let snapshot = self?.monitor?.snapshot {
                    self?.evaluate(snapshot: snapshot)
                }
            }
            .store(in: &cancellables)

        // 监控总开关：关闭即停采样，曲线会冻结在最后一次下发值 — 在此归还风扇
        // 并挂起评估（覆盖设置页开关等全部写入入口）；重开立即按快照接管。
        monitorPreferences.$configuration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in
                guard let self else { return }
                if config.isEnabled {
                    self.resumeFromMonitoringStop()
                    if let snapshot = self.monitor?.snapshot {
                        self.evaluate(snapshot: snapshot)
                    }
                } else {
                    self.suspendForMonitoringStop()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 手动控制（UI 入口）

    /// 设定单风扇手动目标转速；带转速的请求即接管该风扇
    func setManualTarget(index: Int, rpm: Double) {
        manualTargets[index] = rpm
        lastSentRPM[index] = nil  // 手动即时下发，不参与斜坡
        sendManual(index: index, rpm: rpm)
    }

    /// 单风扇归还自动
    func clearManualTarget(index: Int) {
        manualTargets[index] = nil
        lastSentRPM[index] = nil
        helper.setFanAuto(index: index) { [weak self] ok, error in
            Task { @MainActor in
                self?.recordResult(ok: ok, error: error)
            }
        }
    }

    /// 全部归还自动（UI「全部归还」按钮）：同时关闭性能模式偏好，
    /// 避免归还后被仍开启的模式立即重新接管。硬件归还走回执路径：
    /// 成功才清内部状态，失败保留待恢复状态供下轮重试。
    func handBackToAuto() {
        preferences?.update { $0.performanceMode = false }
        handBackHardware()
    }

    /// 手动目标（UI 回显）
    var currentManualTargets: [Int: Double] { manualTargets }

    /// 事件驱动的注册状态刷新（安装/卸载完成、控制页进入时调用）。
    /// SMAppService.status 在后台队列解析，回主线程写缓存 — 调用方永不阻塞。
    func refreshHelperRegistration() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let registered = self?.isHelperRegistered() ?? false
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshInFlight = false
                self.helperRegistered = registered
            }
        }
    }

    // MARK: - 监控停用/恢复（总开关与特性卸载）

    /// 监控停用（总开关关闭或特性卸载）：立即归还自动模式并挂起评估。
    /// 与用户显式「全部归还」不同，不改偏好 — 重开后按原偏好自动接管。
    func suspendForMonitoringStop() {
        monitoringSuspended = true
        handBackHardware()
    }

    /// 监控恢复（总开关重开）：清挂起标志，下一轮快照或即时评估自动接管。
    func resumeFromMonitoringStop() {
        monitoringSuspended = false
    }

    /// 特性卸载终态：归还硬件、断开全部订阅、移除系统观察者、置空依赖。
    /// 此后不再有任何下发路径，风扇完全交还 SMC 自动策略。
    func stop() {
        suspendForMonitoringStop()
        cancellables.removeAll()
        removeSystemObservers()
        monitor = nil
        preferences = nil
        monitorPreferences = nil
    }

    /// 条件归还（回执事务，用户按钮/系统事件/监控停用/退出共用）：
    /// 性能模式、手动目标在位或存在待恢复归还（上次失败）时 resetAllFans；
    /// 串行化（进行中不重复发起），成功才清内部状态，
    /// 失败保留待恢复状态（下轮 evaluate 重试归还）。
    private func handBackHardware() {
        guard !resetInFlight else { return }
        guard resetRecoveryPending || wasPerformanceActive || !manualTargets.isEmpty else {
            resetInternalState()
            return
        }
        resetInFlight = true
        // 请求层立即停止速度下发（reset 与速度命令不并发，晚到命令不覆盖 reset）。
        wasPerformanceActive = false
        manualTargets.removeAll()
        helper.resetAllFans { [weak self] ok, error in
            Task { @MainActor in
                guard let self else { return }
                self.resetInFlight = false
                if ok {
                    self.resetInternalState()
                    self.resetRecoveryPending = false
                } else {
                    // 归还失败：保留待恢复信息（不清成「已自动」），停止曲线下发，
                    // 由下一轮快照重试归还（2s 节奏天然有界）。
                    self.resetRecoveryPending = true
                }
                self.recordResult(ok: ok, error: error)
            }
        }
    }

    /// 应用退出事务（审查 R06）：禁止一切新目标下发，若硬件在控则等待归还回执。
    /// 返回 false = 归还失败，调用方应沿退出失败机制提示重试，不得宣称安全退出。
    /// XPC 层自带 8s 回执超时兜底，此处不会无限等待。
    func shutdownForApplicationTermination() async -> Bool {
        quitting = true
        guard wasPerformanceActive || !manualTargets.isEmpty else {
            return true
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            helper.resetAllFans { [weak self] ok, error in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume(returning: ok)
                        return
                    }
                    if ok {
                        self.resetInternalState()
                        self.wasPerformanceActive = false
                    }
                    self.recordResult(ok: ok, error: error)
                    continuation.resume(returning: ok)
                }
            }
        }
    }

    /// 显式移除系统事件观察者（不依赖 dealloc 时的 zeroing-weak 隐式注销）。
    private func removeSystemObservers() {
        guard observersInstalled else { return }
        observersInstalled = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - 核心评估（快照驱动）

    func evaluate(snapshot: SystemSnapshot) {
        guard !quitting, !systemAsleep, suspensionReasons.isEmpty, !monitoringSuspended else { return }
        guard let preferences else { return }
        // 归还事务进行中或归还失败待恢复：优先完成/重试归还，不下发曲线。
        if resetRecoveryPending {
            handBackHardware()
            return
        }
        guard !resetInFlight else { return }

        // 机型判定：fans 非空即有风扇；风扇轮成功执行（无 issue 且传感器有读数，
        // 证明采样确实跑过）而 fans 为空 = 无风扇机型。未采样轮保持已判定值。
        if !snapshot.fans.isEmpty {
            hasFans = true
        } else if snapshot.issues[.fan] == nil, !snapshot.sensors.isEmpty {
            hasFans = false
        }

        let config = preferences.configuration
        // 只读缓存判定 Helper 可用（同步 XPC 查询禁止进入本热路径）
        guard helperRegistered else {
            if wasPerformanceActive { handBackToAuto() }
            return
        }

        let batterySaving = config.performanceMode
            && config.batterySaverEnabled
            && !config.forcePerformanceOnBattery
            && powerSupply.isOnBatteryBelow(thresholdPercent: config.batterySaverThreshold)
        let performanceActive = config.performanceMode && !batterySaving

        batterySaverSuppressed = config.performanceMode && batterySaving

        // 手动覆盖优先：被接管的风扇直接下发，不进曲线
        dispatchManualTargets()

        // 性能模式关闭/被抑制 → 唯一归还路径
        if wasPerformanceActive && !performanceActive {
            handBackHardware()
            return
        }
        guard performanceActive, !snapshot.fans.isEmpty else { return }
        wasPerformanceActive = true

        let level = config.performanceLevel
        let factor = FanCurve.smoothingFactor(level)
        let floor = FanCurve.minSpeedFloor(level)

        // 各热区峰值 EMA → 曲线百分比
        var zonePercents: [ThermalZone: Double] = [:]
        for zone in ThermalZone.allCases {
            let peak = snapshot.sensors
                .filter { $0.zone == zone }
                .map(\.temperatureCelsius)
                .max()
            guard let peak, peak > 0 else { continue }
            let smoothed = FanCurve.smoothed(
                previous: smoothedZoneTemps[zone],
                current: peak,
                factor: factor
            )
            smoothedZoneTemps[zone] = smoothed
            zonePercents[zone] = FanCurve.speedPercent(level: level, temperature: smoothed)
        }

        // 温度有效性门槛（审查 R07）：无任何有效读数、或 CPU 热区（性能控制的
        // 主要受控对象）无覆盖时，不得按「0 贡献」下发低档目标 —
        // 暂停曲线并归还自动（保留用户偏好与错误状态），有温度后自动接管。
        guard zonePercents[.cpu] != nil else {
            if wasPerformanceActive {
                lastError = "无有效 CPU 温度读数，性能模式暂停并已归还自动控制"
                handBackHardware()
            }
            return
        }

        // 每风扇目标 = max over 热区(曲线% × 亲和度)，地板兜底
        let isSingleFan = snapshot.fans.count <= 1
        var fanPercents: [Int: Double] = [:]
        for fan in snapshot.fans {
            let contribution = zonePercents.compactMap { zone, percent -> Double? in
                guard manualTargets[fan.id] == nil else { return nil }
                let affinity = isSingleFan
                    ? FanZoneAffinity.singleFanAffinity(for: zone)
                    : (fan.id == 0 ? FanZoneAffinity.affinity(for: zone).left
                                   : FanZoneAffinity.affinity(for: zone).right)
                return percent * affinity
            }.max() ?? 0
            fanPercents[fan.id] = max(contribution, floor)
        }

        let maxPercent = fanPercents.values.max() ?? floor
        performanceCurvePercent = maxPercent * 100

        // 下发：斜坡限速 + 100 RPM 取整 + 与上次差 <100 跳过（防 XPC 刷屏）。
        // 去重基线只在命令成功后保留（审查 R08）：失败回滚基线，下轮自动重试。
        for fan in snapshot.fans where manualTargets[fan.id] == nil {
            let percent = fanPercents[fan.id] ?? floor
            let desired = fan.minRPM + percent * (fan.maxRPM - fan.minRPM)
            let ramped = FanCurve.rampedTarget(
                desired: desired,
                lastSent: lastSentRPM[fan.id],
                upRate: FanCurve.rampUpRate(level),
                downRate: FanCurve.rampDownRate(level)
            )
            let rounded = (ramped / 100).rounded() * 100
            if let last = lastSentRPM[fan.id], abs(rounded - last) < 100 { continue }
            let previousBaseline = lastSentRPM[fan.id]
            let fanIndex = fan.id
            lastSentRPM[fanIndex] = rounded
            helper.setFanSpeed(index: fanIndex, rpm: Int(rounded)) { [weak self] ok, error in
                Task { @MainActor in
                    guard let self else { return }
                    if !ok, self.lastSentRPM[fanIndex] == rounded {
                        // 失败回滚到下发前基线，下轮差值仍超阈值会重试
                        if let previous = previousBaseline {
                            self.lastSentRPM[fanIndex] = previous
                        } else {
                            self.lastSentRPM[fanIndex] = nil
                        }
                    }
                    self.recordResult(ok: ok, error: error)
                }
            }
        }
    }

    // MARK: - 系统事件（睡眠/锁屏归还，SPEC §4.5）
    //
    // 系统暂态只挂起与归还硬件，**不改写用户偏好**（审查 R13）：
    // 睡眠/锁屏/屏幕睡眠复用保留偏好的 handBackHardware（唤醒后按原偏好
    // 与新鲜温度重建曲线）；改偏好的 handBackToAuto 只属于用户显式关闭。

    @objc func handleSleep() {
        systemAsleep = true
        handBackHardware()
    }

    @objc func handleWake() {
        systemAsleep = false
        resumeIfNeeded()
    }

    @objc func handleScreenSleep() {
        guard let preferences, !preferences.configuration.keepFansOnScreenSleep else { return }
        suspensionReasons.insert(.screenAsleep)
        handBackHardware()
    }

    @objc func handleScreenWake() {
        suspensionReasons.remove(.screenAsleep)
        resumeIfNeeded()
    }

    @objc func handleScreenLocked() {
        guard let preferences, !preferences.configuration.keepFansOnScreenSleep else { return }
        suspensionReasons.insert(.screenLocked)
        handBackHardware()
    }

    @objc func handleScreenUnlocked() {
        suspensionReasons.remove(.screenLocked)
        resumeIfNeeded()
    }

    func setupSystemObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(handleSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleScreenSleep),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleScreenWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(handleScreenLocked),
                        name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(handleScreenUnlocked),
                        name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    /// 唤醒/解锁后延迟触发一轮立即评估（等待 auto 归还命令送达）
    private func resumeIfNeeded() {
        guard let monitor else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.monitor != nil else { return }
            self.evaluate(snapshot: monitor.snapshot)
        }
    }

    // MARK: - 内部

    private func dispatchManualTargets() {
        for (index, rpm) in manualTargets {
            sendManual(index: index, rpm: rpm)
        }
    }

    private func sendManual(index: Int, rpm: Double) {
        helper.setFanSpeed(index: index, rpm: Int(rpm)) { [weak self] ok, error in
            Task { @MainActor in self?.recordResult(ok: ok, error: error) }
        }
    }

    private func recordResult(ok: Bool, error: String?) {
        lastError = ok ? nil : error
    }

    /// 清空曲线内部状态（归还后旧缓存不再可信）。
    /// batterySaverSuppressed 不在此清 — 它反映省电抑制的持续状态，
    /// 由下一轮评估或模式关闭更新。
    private func resetInternalState() {
        smoothedZoneTemps.removeAll()
        lastSentRPM.removeAll()
        manualTargets.removeAll()
        performanceCurvePercent = 0
    }
}
