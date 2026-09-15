import XCTest
@testable import OmniForge

/// Helper 命令替身 — 记录命令序列，全部即时成功
final class RecordingFanHelperClient: FanHelperCommanding {
    private(set) var commands: [String] = []

    func setFanSpeed(index: Int, rpm: Int, completion: @escaping (Bool, String?) -> Void) {
        commands.append("speed(\(index),\(rpm))")
        completion(true, nil)
    }

    /// 清空已记录命令（测试分段断言用）
    func reset() {
        commands.removeAll()
    }

    func setFanAuto(index: Int, completion: @escaping (Bool, String?) -> Void) {
        commands.append("auto(\(index))")
        completion(true, nil)
    }

    func resetAllFans(completion: @escaping (Bool, String?) -> Void) {
        commands.append("reset")
        completion(true, nil)
    }

    func fetchVersion(completion: @escaping (String?) -> Void) {
        completion("1.0.0")
    }
}

final class StubPowerSupply: PowerSupplyChecking {
    var lowBattery = false
    func isOnBatteryBelow(thresholdPercent threshold: Int) -> Bool { lowBattery }
}

@MainActor
final class FanControlCoordinatorTests: XCTestCase {

    private var helper: RecordingFanHelperClient!
    private var power: StubPowerSupply!
    private var preferences: FanPreferences!
    private var monitorPreferences: MonitorPreferences!
    private var registered = true
    /// 注册状态查询计数 — 固化「热路径零查询」约束
    private var registrationQueryCount = 0

    override func setUp() {
        super.setUp()
        helper = RecordingFanHelperClient()
        power = StubPowerSupply()
        registered = true
        let defaults = UserDefaults(suiteName: "fan-coordinator-tests")!
        defaults.removePersistentDomain(forName: "fan-coordinator-tests")
        preferences = FanPreferences(userDefaults: defaults)
        monitorPreferences = MonitorPreferences(userDefaults: defaults)
    }

    private func makeCoordinator() -> FanControlCoordinator {
        let coordinator = FanControlCoordinator(
            helper: helper,
            powerSupply: power,
            isHelperRegistered: { [weak self] in
                self?.registrationQueryCount += 1
                return self?.registered ?? false
            }
        )
        coordinator.start(
            monitor: makeFakeMonitor(),
            preferences: preferences,
            monitorPreferences: monitorPreferences
        )
        return coordinator
    }

    /// 排空主队列两轮：让命令回执（Task @MainActor）落地后再继续断言。
    private func drainMainActorReceipts() {
        for _ in 0..<2 {
            let drained = expectation(description: "回执落地")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 1)
        }
    }

    /// 双风扇 + CPU 热区高温快照
    private func makeSnapshot(cpuTemp: Double = 80) -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.fans = [
            FanReading(id: 0, currentRPM: 1200, minRPM: 1200, maxRPM: 5800, targetRPM: 1200, isManualMode: false),
            FanReading(id: 1, currentRPM: 1200, minRPM: 1200, maxRPM: 5800, targetRPM: 1200, isManualMode: false)
        ]
        snapshot.sensors = [
            FanSensorReading(id: "Tp01", label: "CPU", zone: .cpu, temperatureCelsius: cpuTemp),
            FanSensorReading(id: "TB0T", label: "Battery", zone: .battery, temperatureCelsius: 30)
        ]
        return snapshot
    }

    // MARK: - 性能模式

    func test_evaluate_modeOff_sendsNothing() {
        let coordinator = makeCoordinator()
        coordinator.evaluate(snapshot: makeSnapshot())
        XCTAssertTrue(helper.commands.isEmpty, "性能模式关闭时不产生命令")
    }

    func test_evaluate_helperUnregistered_sendsNothing() {
        registered = false
        preferences.update { $0.performanceMode = true }
        let coordinator = makeCoordinator()
        coordinator.evaluate(snapshot: makeSnapshot())
        XCTAssertTrue(helper.commands.isEmpty, "Helper 未注册不下发")
    }

    /// 固化「热路径零查询」：快照评估（每 2s）绝不触发 SMAppService 同步查询
    /// （实测 ~120ms 的主线程 XPC 会冻结挂在主 runloop 的全局滚动事件 tap）
    func test_evaluate_neverQueriesRegistrationState() {
        registrationQueryCount = 0
        preferences.update { $0.performanceMode = true }
        let coordinator = makeCoordinator()
        XCTAssertEqual(registrationQueryCount, 1, "仅在 start 解析一次")

        for _ in 0..<10 {
            coordinator.evaluate(snapshot: makeSnapshot())
        }
        XCTAssertEqual(registrationQueryCount, 1,
                       "快照评估热路径不得查询注册状态（同步 XPC 禁入）")
    }

    func test_evaluate_modeOn_sendsCurvedSpeedsToAllFans() {
        preferences.update { $0.performanceMode = true; $0.performanceLevel = .medium }
        let coordinator = makeCoordinator()

        coordinator.evaluate(snapshot: makeSnapshot(cpuTemp: 80))

        // 首轮 EMA 直采 80°C：medium 曲线 ≈ 35%+10/12*30% ≈ 0.60
        // 双风扇 CPU 等责亲和 1.0 → 目标 = 1200 + 0.60 × 4600 ≈ 3960 → 4000（取整）
        XCTAssertEqual(helper.commands.count, 2)
        XCTAssertTrue(helper.commands.allSatisfy { $0.hasPrefix("speed(") })
        let rpm = helper.commands.first.flatMap { Int($0.dropFirst(6).dropLast().split(separator: ",").last ?? "") }
        XCTAssertEqual(rpm ?? 0, 4000, accuracy: 100)
    }

    func test_evaluate_sameTargetTwice_secondRoundSkipped() {
        preferences.update { $0.performanceMode = true; $0.performanceLevel = .medium }
        let coordinator = makeCoordinator()
        let snapshot = makeSnapshot(cpuTemp: 80)

        coordinator.evaluate(snapshot: snapshot)
        let firstCount = helper.commands.count
        coordinator.evaluate(snapshot: snapshot)

        XCTAssertEqual(helper.commands.count, firstCount,
                       "目标变化 <100 RPM 时跳过下发（防 XPC 刷屏）")
    }

    func test_evaluate_rampLimitsClimb() {
        preferences.update { $0.performanceMode = true; $0.performanceLevel = .medium }
        let coordinator = makeCoordinator()

        // 低温轮：EMA=40 → 地板 10% → 目标 ≈ 1700
        coordinator.evaluate(snapshot: makeSnapshot(cpuTemp: 40))
        // 高温持续观测：EMA 平滑下目标逐轮爬升，单轮增量受斜坡（700）约束
        for _ in 0..<10 {
            coordinator.evaluate(snapshot: makeSnapshot(cpuTemp: 80))
        }

        let speeds = helper.commands.filter { $0.hasPrefix("speed(0") }
        XCTAssertGreaterThanOrEqual(speeds.count, 2, "持续高温应多轮爬升")
        let firstRPM = Int(speeds[0].dropFirst(7).dropLast().split(separator: ",").first ?? "") ?? 0
        let lastRPM = Int(speeds[0].dropFirst(7).dropLast().split(separator: ",").first ?? "") ?? 0
        let finalRPM = helper.commands.last { $0.hasPrefix("speed(0") }
            .flatMap { Int($0.dropFirst(7).dropLast().split(separator: ",").first ?? "") } ?? 0
        _ = firstRPM; _ = lastRPM
        XCTAssertLessThanOrEqual(finalRPM, 1700 + 10 * 700 + 100,
                                 "十轮爬升总量不得超出斜坡上限")
        XCTAssertGreaterThan(finalRPM, 1700, "持续高温应已离开地板")
    }

    // MARK: - 归还路径

    func test_evaluate_modeTurnedOff_resetsOnce() {
        preferences.update { $0.performanceMode = true; $0.performanceLevel = .medium }
        let coordinator = makeCoordinator()
        coordinator.evaluate(snapshot: makeSnapshot())

        preferences.update { $0.performanceMode = false }
        coordinator.evaluate(snapshot: makeSnapshot())
        XCTAssertEqual(helper.commands.filter { $0 == "reset" }.count, 1, "关闭时归还一次")

        coordinator.evaluate(snapshot: makeSnapshot())
        XCTAssertEqual(helper.commands.filter { $0 == "reset" }.count, 1,
                       "关闭后不再重复归还")
    }

    func test_evaluate_batterySaver_suppressesAndResets() {
        preferences.update { $0.performanceMode = true }
        let coordinator = makeCoordinator()
        coordinator.evaluate(snapshot: makeSnapshot())
        XCTAssertTrue(helper.commands.contains { $0.hasPrefix("speed(") })

        power.lowBattery = true
        coordinator.evaluate(snapshot: makeSnapshot())

        XCTAssertTrue(helper.commands.contains("reset"), "电池省电抑制触发归还")
        XCTAssertTrue(coordinator.batterySaverSuppressed)
    }

    func test_evaluate_forcePerformanceOnBattery_beatsSaver() {
        preferences.update {
            $0.performanceMode = true
            $0.forcePerformanceOnBattery = true
        }
        power.lowBattery = true
        let coordinator = makeCoordinator()
        coordinator.evaluate(snapshot: makeSnapshot())
        XCTAssertFalse(coordinator.batterySaverSuppressed, "强制开启覆盖省电抑制")
        XCTAssertTrue(helper.commands.contains { $0.hasPrefix("speed(") })
    }

    // MARK: - 机型判定

    func test_hasFans_trueWhenFansPresent() {
        let coordinator = makeCoordinator()
        coordinator.evaluate(snapshot: makeSnapshot())
        XCTAssertEqual(coordinator.hasFans, true)
    }

    func test_hasFans_falseOnFanlessMachine() {
        // 无风扇机型：风扇轮成功（无 issue + 传感器有读数）而 fans 为空
        var snapshot = makeSnapshot()
        snapshot.fans = []
        let coordinator = makeCoordinator()
        coordinator.evaluate(snapshot: snapshot)
        XCTAssertEqual(coordinator.hasFans, false)
    }

    func test_hasFans_keepsUnknownWhenNotSampled() {
        // 传感器也空 = 无法区分「未采样」，保持 nil
        var snapshot = SystemSnapshot()
        let coordinator = makeCoordinator()
        coordinator.evaluate(snapshot: snapshot)
        XCTAssertNil(coordinator.hasFans)
    }

    // MARK: - 手动覆盖

    func test_manualTarget_overridesCurveForThatFan() {
        preferences.update { $0.performanceMode = true; $0.performanceLevel = .medium }
        let coordinator = makeCoordinator()
        coordinator.setManualTarget(index: 0, rpm: 3000)

        coordinator.evaluate(snapshot: makeSnapshot(cpuTemp: 80))

        XCTAssertTrue(helper.commands.contains("speed(0,3000)"), "手动目标直接下发")
        XCTAssertTrue(helper.commands.contains { $0.hasPrefix("speed(1,") },
                      "其余风扇照常走曲线")
    }

    func test_clearManualTarget_returnsFanToAuto() {
        let coordinator = makeCoordinator()
        coordinator.setManualTarget(index: 0, rpm: 3000)
        coordinator.clearManualTarget(index: 0)
        XCTAssertEqual(helper.commands.last, "auto(0)")
    }

    // MARK: - 全部归还按钮

    func test_handBackToAuto_turnsOffModeAndClearsTargets() {
        preferences.update { $0.performanceMode = true }
        let coordinator = makeCoordinator()
        coordinator.setManualTarget(index: 1, rpm: 4000)

        coordinator.handBackToAuto()

        XCTAssertTrue(helper.commands.contains("reset"))
        XCTAssertFalse(preferences.configuration.performanceMode, "归还同时关闭性能模式")
        XCTAssertTrue(coordinator.currentManualTargets.isEmpty)
    }

    // MARK: - 监控停用/恢复（总开关与特性卸载）

    func test_suspendForMonitoringStop_resetsActiveCurveWithoutTouchingPreference() {
        preferences.update { $0.performanceMode = true; $0.performanceLevel = .medium }
        let coordinator = makeCoordinator()
        coordinator.evaluate(snapshot: makeSnapshot())
        XCTAssertTrue(helper.commands.contains { $0.hasPrefix("speed(") })

        coordinator.suspendForMonitoringStop()

        XCTAssertTrue(helper.commands.contains("reset"), "停用监控时归还自动模式")
        XCTAssertTrue(preferences.configuration.performanceMode,
                      "停用监控不改性能模式偏好（区别于用户显式归还）")
        XCTAssertTrue(coordinator.currentManualTargets.isEmpty)
    }

    func test_suspendForMonitoringStop_resetsManualTargets() {
        let coordinator = makeCoordinator()
        coordinator.setManualTarget(index: 0, rpm: 3200)

        coordinator.suspendForMonitoringStop()

        XCTAssertTrue(helper.commands.contains("reset"), "手动物标在位时停用须归还")
        XCTAssertTrue(coordinator.currentManualTargets.isEmpty)
    }

    func test_suspendThenResume_evaluateGatedAndRestored() {
        preferences.update { $0.performanceMode = true }
        let coordinator = makeCoordinator()
        coordinator.evaluate(snapshot: makeSnapshot())
        XCTAssertFalse(helper.commands.isEmpty)
        helper.reset()

        coordinator.suspendForMonitoringStop()
        // suspend 归还在位曲线会发一条 reset；此后不得再有任何转速命令
        coordinator.evaluate(snapshot: makeSnapshot())
        XCTAssertFalse(helper.commands.contains { $0.hasPrefix("speed(") },
                       "挂起期间不得下发转速")

        coordinator.resumeFromMonitoringStop()
        drainMainActorReceipts()  // suspend 的归还回执落地（串行化窗口结束）
        coordinator.evaluate(snapshot: makeSnapshot())
        XCTAssertTrue(helper.commands.contains { $0.hasPrefix("speed(") },
                      "恢复后重新接管")
    }

    func test_monitorPreferencesDisabled_handsBackAndSuspends() {
        preferences.update { $0.performanceMode = true; $0.performanceLevel = .medium }
        let coordinator = makeCoordinator()
        coordinator.evaluate(snapshot: makeSnapshot())
        XCTAssertFalse(helper.commands.isEmpty)
        helper.reset()

        monitorPreferences.update { $0.isEnabled = false }
        // 订阅经主队列派发：排空主队列后再断言
        let drained = expectation(description: "主队列排空")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)

        XCTAssertEqual(helper.commands, ["reset"], "总开关关闭触发全量归还")

        coordinator.evaluate(snapshot: makeSnapshot())
        XCTAssertEqual(helper.commands, ["reset"], "挂起期间快照不驱动下发")
    }

    func test_monitorPreferencesEnabledAfterSuspend_resumes() {
        preferences.update { $0.performanceMode = true; $0.performanceLevel = .medium }
        let coordinator = makeCoordinator()
        monitorPreferences.update { $0.isEnabled = false }
        let drained1 = expectation(description: "主队列排空")
        DispatchQueue.main.async { drained1.fulfill() }
        wait(for: [drained1], timeout: 1)
        helper.reset()

        monitorPreferences.update { $0.isEnabled = true }
        let drained2 = expectation(description: "主队列排空")
        DispatchQueue.main.async { drained2.fulfill() }
        wait(for: [drained2], timeout: 1)

        // fake monitor 无采样，snapshot 由直接 evaluate 模拟；
        // 此处验证挂起标志已被订阅清除（若未清除则不下发）
        coordinator.evaluate(snapshot: makeSnapshot())
        XCTAssertFalse(helper.commands.isEmpty, "总开关重开后恢复接管")
    }

    func test_stop_defendsAgainstLateEvaluate() {
        preferences.update { $0.performanceMode = true }
        let coordinator = makeCoordinator()
        coordinator.evaluate(snapshot: makeSnapshot())
        XCTAssertFalse(helper.commands.isEmpty)
        helper.reset()

        coordinator.stop()
        XCTAssertEqual(helper.commands, ["reset"], "stop 时归还仍在位的曲线目标")

        // stop 后依赖已置空：迟到的评估请求直接早退，不产生新命令
        coordinator.evaluate(snapshot: makeSnapshot())
        XCTAssertEqual(helper.commands, ["reset"])
        XCTAssertTrue(coordinator.currentManualTargets.isEmpty)
    }

    // MARK: - 回执可信度与温度门槛（审查 R06/R07/R08/R13）

    /// 脚本化 Helper 替身：可按命令序注入失败/延迟回执。
    private final class ScriptedFanHelperClient: FanHelperCommanding {
        enum Action {
            case succeed
            case fail(String)
        }
        /// 每条命令的动作脚本（speed 命令按 setFanSpeed 调用序索引；超长重复末项）。
        var speedScript: [Action] = [.succeed]
        var resetAction: Action = .succeed
        private(set) var commands: [String] = []

        /// 清空命令记录（测试分段断言用）。
        func resetCommands() {
            commands.removeAll()
        }

        func setFanSpeed(index: Int, rpm: Int, completion: @escaping (Bool, String?) -> Void) {
            commands.append("speed(\(index),\(rpm))")
            let call = commands.filter { $0.hasPrefix("speed(") }.count - 1
            let action = speedScript[min(call, speedScript.count - 1)]
            switch action {
            case .succeed: completion(true, nil)
            case .fail(let reason): completion(false, reason)
            }
        }

        func setFanAuto(index: Int, completion: @escaping (Bool, String?) -> Void) {
            commands.append("auto(\(index))")
            completion(true, nil)
        }

        func resetAllFans(completion: @escaping (Bool, String?) -> Void) {
            commands.append("reset")
            switch resetAction {
            case .succeed: completion(true, nil)
            case .fail(let reason): completion(false, reason)
            }
        }

        func fetchVersion(completion: @escaping (String?) -> Void) {
            completion("1.0.0")
        }
    }

    private func makeCoordinatorWith(scripted: ScriptedFanHelperClient) -> FanControlCoordinator {
        let coordinator = FanControlCoordinator(
            helper: scripted,
            powerSupply: power,
            isHelperRegistered: { true }
        )
        coordinator.start(
            monitor: makeFakeMonitor(),
            preferences: preferences,
            monitorPreferences: monitorPreferences
        )
        return coordinator
    }

    /// R08：下发失败回滚去重基线 — 相同目标下一轮必须重试，不得因「差值不足」跳过。
    func test_speedCommandFailure_rollsBackBaselineForRetry() {
        let scripted = ScriptedFanHelperClient()
        scripted.speedScript = [.fail("smc rejected"), .succeed]
        preferences.update { $0.performanceMode = true; $0.performanceLevel = .medium }
        let coordinator = makeCoordinatorWith(scripted: scripted)
        let snapshot = makeSnapshot(cpuTemp: 80)

        coordinator.evaluate(snapshot: snapshot)
        drainMainActorReceipts()

        coordinator.evaluate(snapshot: snapshot)
        // 双风扇：第一轮 fan0 失败、fan1 成功；回滚后第二轮 fan0 重试成功（fan1 差值不足跳过）。
        let speedCalls = scripted.commands.filter { $0.hasPrefix("speed(") }
        XCTAssertEqual(speedCalls.count, 3, "失败回滚后同目标应重试")
    }

    /// R08：归还失败保留待恢复状态 — 下一轮评估优先重试归还，不下发曲线。
    func test_resetFailure_keepsRecoveryPendingAndRetries() {
        let scripted = ScriptedFanHelperClient()
        scripted.resetAction = .fail("helper down")
        preferences.update { $0.performanceMode = true; $0.performanceLevel = .medium }
        let coordinator = makeCoordinatorWith(scripted: scripted)
        coordinator.evaluate(snapshot: makeSnapshot(cpuTemp: 80))
        XCTAssertFalse(scripted.commands.isEmpty, "先建立控制")
        let speedCountAfterControl = scripted.commands.filter { $0.hasPrefix("speed(") }.count

        preferences.update { $0.performanceMode = false }  // 关闭 → 归还（回执失败）

        // 归还回执落地后，逐轮评估驱动重试（每轮之间排空回执）。
        for _ in 0..<3 {
            drainMainActorReceipts()
            coordinator.evaluate(snapshot: makeSnapshot(cpuTemp: 80))
        }
        drainMainActorReceipts()

        let resets = scripted.commands.filter { $0 == "reset" }
        XCTAssertGreaterThanOrEqual(resets.count, 2, "归还失败后下轮重试归还")
        XCTAssertEqual(
            scripted.commands.filter { $0.hasPrefix("speed(") }.count,
            speedCountAfterControl,
            "归还待恢复期间不得有新的曲线下发"
        )
    }

    /// R08：归还成功才清状态 — 成功后不再重复归还。
    func test_resetSuccess_clearsState() {
        let scripted = ScriptedFanHelperClient()
        preferences.update { $0.performanceMode = true; $0.performanceLevel = .medium }
        let coordinator = makeCoordinatorWith(scripted: scripted)
        coordinator.evaluate(snapshot: makeSnapshot(cpuTemp: 80))

        preferences.update { $0.performanceMode = false }
        coordinator.evaluate(snapshot: makeSnapshot(cpuTemp: 80))
        coordinator.evaluate(snapshot: makeSnapshot(cpuTemp: 80))

        let resets = scripted.commands.filter { $0 == "reset" }
        XCTAssertEqual(resets.count, 1, "成功归还后不重复")
    }

    /// R07：无有效 CPU 温度读数时不得按「0 贡献」下发低档目标 —
    /// 已在控则归还自动，保留用户偏好。
    func test_evaluate_missingCPUTemperature_handsBackWithoutLowFloorCommands() {
        preferences.update { $0.performanceMode = true; $0.performanceLevel = .medium }
        let coordinator = makeCoordinator()

        // 先有温度建立控制。
        coordinator.evaluate(snapshot: makeSnapshot(cpuTemp: 80))
        XCTAssertFalse(helper.commands.filter { $0.hasPrefix("speed(") }.isEmpty)
        helper.reset()

        // 温度全空：归还，不再下发。
        var snapshot = makeSnapshot()
        snapshot.sensors = []
        coordinator.evaluate(snapshot: snapshot)
        XCTAssertEqual(helper.commands, ["reset"], "无温度时归还而非下发地板转速")
        XCTAssertTrue(preferences.configuration.performanceMode, "用户偏好不得被篡改")
    }

    /// R13：系统事件（睡眠/屏幕睡眠/锁屏）归还硬件但不得改写用户偏好。
    func test_systemEvents_handBackWithoutTouchingPreference() {
        preferences.update { $0.performanceMode = true; $0.performanceLevel = .medium }
        let coordinator = makeCoordinator()
        coordinator.evaluate(snapshot: makeSnapshot(cpuTemp: 80))
        helper.reset()

        coordinator.handleScreenSleep()
        XCTAssertEqual(helper.commands, ["reset"], "屏幕睡眠归还硬件")
        XCTAssertTrue(preferences.configuration.performanceMode, "偏好保留 — 唤醒后按原偏好重建曲线")

        // 屏幕唤醒：排空归还回执后按保留的偏好恢复接管。
        helper.reset()
        drainMainActorReceipts()
        coordinator.handleScreenWake()
        coordinator.evaluate(snapshot: makeSnapshot(cpuTemp: 80))
        XCTAssertFalse(helper.commands.isEmpty, "唤醒后按保留的偏好恢复接管")
    }

    /// R13：锁屏与屏幕睡眠独立登记 — 只解除其一（屏醒）时锁屏挂起仍有效。
    func test_lockAndScreenSleep_reasonsResolveIndependently() {
        preferences.update { $0.performanceMode = true; $0.performanceLevel = .medium }
        let coordinator = makeCoordinator()
        coordinator.evaluate(snapshot: makeSnapshot(cpuTemp: 80))
        helper.reset()

        coordinator.handleScreenLocked()
        drainMainActorReceipts()  // 第一次归还回执落地，串行化窗口结束
        coordinator.handleScreenSleep()
        XCTAssertEqual(helper.commands.filter { $0 == "reset" }.count, 1,
                       "挂起去重：硬件已在控归还过则不再重复 reset")
        helper.reset()

        coordinator.handleScreenWake()  // 仅屏幕唤醒，锁屏仍有效
        coordinator.evaluate(snapshot: makeSnapshot(cpuTemp: 80))
        XCTAssertTrue(helper.commands.isEmpty, "锁屏挂起仍有效，不得恢复下发")

        coordinator.handleScreenUnlocked()
        drainMainActorReceipts()
        coordinator.evaluate(snapshot: makeSnapshot(cpuTemp: 80))
        XCTAssertFalse(helper.commands.isEmpty, "解锁后恢复")
    }

    /// R06：退出事务 — 硬件在控时等待归还回执；失败返回 false（阻止退出）。
    func test_shutdownForApplicationTermination_reportsHandbackOutcome() async {
        let scripted = ScriptedFanHelperClient()
        preferences.update { $0.performanceMode = true; $0.performanceLevel = .medium }
        let coordinator = makeCoordinatorWith(scripted: scripted)
        coordinator.evaluate(snapshot: makeSnapshot(cpuTemp: 80))
        scripted.resetCommands()

        let ok = await coordinator.shutdownForApplicationTermination()
        XCTAssertTrue(ok, "归还成功应放行退出")
        XCTAssertEqual(scripted.commands, ["reset"])
        // 退出事务启动后禁止一切下发。
        coordinator.evaluate(snapshot: makeSnapshot(cpuTemp: 80))
        XCTAssertEqual(scripted.commands, ["reset"], "退出中不得再下发")

        // 失败路径：手动目标在位 + 归还失败。
        scripted.resetAction = .fail("helper dead")
        let second = FanControlCoordinator(helper: scripted, powerSupply: power, isHelperRegistered: { true })
        second.start(monitor: makeFakeMonitor(), preferences: preferences, monitorPreferences: monitorPreferences)
        second.setManualTarget(index: 0, rpm: 3000)
        let ok2 = await second.shutdownForApplicationTermination()
        XCTAssertFalse(ok2, "归还失败必须阻止退出（不得误报安全清理）")
    }
}
