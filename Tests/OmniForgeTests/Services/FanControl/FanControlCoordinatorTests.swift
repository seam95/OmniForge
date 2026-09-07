import XCTest
@testable import OmniForge

/// Helper 命令替身 — 记录命令序列，全部即时成功
final class RecordingFanHelperClient: FanHelperCommanding {
    private(set) var commands: [String] = []

    func setFanSpeed(index: Int, rpm: Int, completion: @escaping (Bool, String?) -> Void) {
        commands.append("speed(\(index),\(rpm))")
        completion(true, nil)
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
    private var registered = true

    override func setUp() {
        super.setUp()
        helper = RecordingFanHelperClient()
        power = StubPowerSupply()
        registered = true
        let defaults = UserDefaults(suiteName: "fan-coordinator-tests")!
        defaults.removePersistentDomain(forName: "fan-coordinator-tests")
        preferences = FanPreferences(userDefaults: defaults)
    }

    private func makeCoordinator() -> FanControlCoordinator {
        let coordinator = FanControlCoordinator(
            helper: helper,
            powerSupply: power,
            isHelperRegistered: { [weak self] in self?.registered ?? false }
        )
        coordinator.start(monitor: makeFakeMonitor(), preferences: preferences)
        return coordinator
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
}
