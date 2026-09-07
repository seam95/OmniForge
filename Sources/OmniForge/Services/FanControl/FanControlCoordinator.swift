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

    private let helper: FanHelperCommanding
    private let powerSupply: PowerSupplyChecking
    /// Helper 注册状态边界 — 生产查 SMAppService，测试注入固定值
    private let isHelperRegistered: () -> Bool
    private var preferences: FanPreferences?
    private var monitor: SystemMonitorManager?
    private var cancellables = Set<AnyCancellable>()

    private var smoothedZoneTemps: [ThermalZone: Double] = [:]
    private var lastSentRPM: [Int: Double] = [:]
    /// 手动覆盖目标（风扇序号 → RPM）；手动风扇不参与曲线计算
    private var manualTargets: [Int: Double] = [:]
    private var wasPerformanceActive = false
    private var systemAsleep = false
    private var performanceSuspended = false
    private var observersInstalled = false

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

    /// 订阅监控快照与偏好变化；在 FeatureFactory 装配时调用一次
    func start(monitor: SystemMonitorManager, preferences: FanPreferences) {
        self.monitor = monitor
        self.preferences = preferences
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
    /// 避免归还后被仍开启的模式立即重新接管
    func handBackToAuto() {
        preferences?.update { $0.performanceMode = false }
        helper.resetAllFans { [weak self] ok, error in
            Task { @MainActor in
                self?.recordResult(ok: ok, error: error)
            }
        }
        resetInternalState()
    }

    /// 手动目标（UI 回显）
    var currentManualTargets: [Int: Double] { manualTargets }

    // MARK: - 核心评估（快照驱动）

    func evaluate(snapshot: SystemSnapshot) {
        guard !systemAsleep, !performanceSuspended else { return }
        guard let preferences else { return }

        let config = preferences.configuration
        // Helper 未注册时不下发（监控照常，控制不可用）
        guard isHelperRegistered() else {
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
            wasPerformanceActive = false
            helper.resetAllFans { [weak self] ok, error in
                Task { @MainActor in self?.recordResult(ok: ok, error: error) }
            }
            resetInternalState()
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

        // 下发：斜坡限速 + 100 RPM 取整 + 与上次差 <100 跳过（防 XPC 刷屏）
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
            lastSentRPM[fan.id] = rounded
            helper.setFanSpeed(index: fan.id, rpm: Int(rounded)) { [weak self] ok, error in
                Task { @MainActor in self?.recordResult(ok: ok, error: error) }
            }
        }
    }

    // MARK: - 系统事件（睡眠/锁屏归还，SPEC §4.5）

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

    @objc private func handleSleep() {
        systemAsleep = true
        handBackToAuto()
    }

    @objc private func handleWake() {
        systemAsleep = false
        resumeIfNeeded()
    }

    @objc private func handleScreenSleep() {
        guard let preferences, !preferences.configuration.keepFansOnScreenSleep else { return }
        performanceSuspended = true
        handBackToAuto()
    }

    @objc private func handleScreenWake() {
        performanceSuspended = false
        resumeIfNeeded()
    }

    @objc private func handleScreenLocked() {
        guard let preferences, !preferences.configuration.keepFansOnScreenSleep else { return }
        performanceSuspended = true
        handBackToAuto()
    }

    @objc private func handleScreenUnlocked() {
        performanceSuspended = false
        resumeIfNeeded()
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
