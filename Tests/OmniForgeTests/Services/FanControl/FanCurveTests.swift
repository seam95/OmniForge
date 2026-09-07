import XCTest
@testable import OmniForge

final class FanCurveTests: XCTestCase {

    // MARK: - 拐点值

    func test_lowLevel_breakpoints() {
        XCTAssertEqual(FanCurve.speedPercent(level: .low, temperature: 25), 0.0)
        XCTAssertEqual(FanCurve.speedPercent(level: .low, temperature: 70), 0.0, accuracy: 1e-9)
        XCTAssertEqual(FanCurve.speedPercent(level: .low, temperature: 85), 0.30, accuracy: 1e-9)
        XCTAssertEqual(FanCurve.speedPercent(level: .low, temperature: 95), 0.60, accuracy: 1e-9)
        XCTAssertEqual(FanCurve.speedPercent(level: .low, temperature: 105), 0.80, accuracy: 1e-9)
        XCTAssertEqual(FanCurve.speedPercent(level: .low, temperature: 120), 0.80)
    }

    func test_mediumLevel_breakpoints() {
        XCTAssertEqual(FanCurve.speedPercent(level: .medium, temperature: 40), 0.10)
        XCTAssertEqual(FanCurve.speedPercent(level: .medium, temperature: 70), 0.35, accuracy: 1e-9)
        XCTAssertEqual(FanCurve.speedPercent(level: .medium, temperature: 82), 0.65, accuracy: 1e-9)
        XCTAssertEqual(FanCurve.speedPercent(level: .medium, temperature: 92), 0.90, accuracy: 1e-9)
        XCTAssertGreaterThan(FanCurve.speedPercent(level: .medium, temperature: 100), 0.90)
        XCTAssertLessThanOrEqual(FanCurve.speedPercent(level: .medium, temperature: 130), 1.0)
    }

    func test_highLevel_breakpoints() {
        XCTAssertEqual(FanCurve.speedPercent(level: .high, temperature: 35), 0.25)
        XCTAssertEqual(FanCurve.speedPercent(level: .high, temperature: 82), 0.95, accuracy: 1e-9)
        XCTAssertEqual(FanCurve.speedPercent(level: .high, temperature: 90), 1.0)
    }

    func test_maxLevel_breakpoints() {
        XCTAssertEqual(FanCurve.speedPercent(level: .max, temperature: 30), 0.50)
        XCTAssertEqual(FanCurve.speedPercent(level: .max, temperature: 68), 1.0, accuracy: 1e-9)
        XCTAssertEqual(FanCurve.speedPercent(level: .max, temperature: 80), 1.0)
    }

    // MARK: - 曲线性质

    /// 各档曲线单调不减（温度升高转速占比不降）
    func test_allLevels_areMonotonicallyNondecreasing() {
        for level in FanCurve.Level.allCases {
            var previous = -1.0
            var temp = 20.0
            while temp <= 120 {
                let percent = FanCurve.speedPercent(level: level, temperature: temp)
                XCTAssertGreaterThanOrEqual(percent, previous, "\(level) 在 \(temp)°C 出现降速")
                previous = percent
                temp += 1
            }
        }
    }

    /// 段边界连续（拐点两侧 0.01°C 差值内的输出跳变 < 2.5%）
    func test_allLevels_areContinuousAtSegmentBoundaries() {
        for level in FanCurve.Level.allCases {
            for boundary in [40.0, 45, 55, 58, 68, 70, 82, 85, 92, 95, 105] {
                let below = FanCurve.speedPercent(level: level, temperature: boundary - 0.01)
                let above = FanCurve.speedPercent(level: level, temperature: boundary + 0.01)
                XCTAssertLessThan(abs(above - below), 0.025,
                                  "\(level) 在 \(boundary)°C 拐点有悬崖")
            }
        }
    }

    /// 输出域约束在 0...1
    func test_outputStaysInUnitInterval() {
        for level in FanCurve.Level.allCases {
            XCTAssertGreaterThanOrEqual(FanCurve.speedPercent(level: level, temperature: 0), 0)
            XCTAssertLessThanOrEqual(FanCurve.speedPercent(level: level, temperature: 200), 1)
        }
    }

    /// 档位地板随档位递增（低 < 中 < 高 < 最高）
    func test_floorIncreasesWithLevel() {
        let floors = FanCurve.Level.allCases.map { FanCurve.minSpeedFloor($0) }
        XCTAssertEqual(floors, floors.sorted())
        XCTAssertEqual(floors, [0.0, 0.10, 0.25, 0.50])
    }

    /// 升速限速恒快于降速（快速响应、缓慢回落）
    func test_rampUpAlwaysFasterThanDown() {
        for level in FanCurve.Level.allCases {
            XCTAssertGreaterThan(FanCurve.rampUpRate(level), FanCurve.rampDownRate(level))
        }
    }

    // MARK: - 平滑与斜坡

    func test_smoothed_firstObservationAdoptedDirectly() {
        XCTAssertEqual(FanCurve.smoothed(previous: nil, current: 88.0, factor: 0.25), 88.0)
    }

    func test_smoothed_convergesTowardCurrent() {
        var value: Double? = 50
        for _ in 0..<50 {
            value = FanCurve.smoothed(previous: value, current: 90, factor: 0.25)
        }
        XCTAssertEqual(value ?? 0, 90, accuracy: 0.5, "EMA 应收敛到持续观测值")
    }

    func test_rampedTarget_climbsByAtMostUpRate() {
        let ramped = FanCurve.rampedTarget(desired: 5800, lastSent: 3200, upRate: 700, downRate: 250)
        XCTAssertEqual(ramped, 3900)
    }

    func test_rampedTarget_descendsByAtMostDownRate() {
        let ramped = FanCurve.rampedTarget(desired: 1200, lastSent: 3200, upRate: 700, downRate: 250)
        XCTAssertEqual(ramped, 2950)
    }

    func test_rampedTarget_firstSendUnclamped() {
        XCTAssertEqual(FanCurve.rampedTarget(desired: 5800, lastSent: nil, upRate: 400, downRate: 150), 5800)
    }
}

final class FanZoneAffinityTests: XCTestCase {

    func test_affinity_allZonesCovered_andInUnitRange() {
        for zone in ThermalZone.allCases {
            let pair = FanZoneAffinity.affinity(for: zone)
            XCTAssertTrue((0...1).contains(pair.left), "\(zone) 左风扇亲和度越界")
            XCTAssertTrue((0...1).contains(pair.right), "\(zone) 右风扇亲和度越界")
            XCTAssertGreaterThan(FanZoneAffinity.singleFanAffinity(for: zone), 0)
        }
    }

    func test_affinity_ssdBiasedToRightFan() {
        let pair = FanZoneAffinity.affinity(for: .ssd)
        XCTAssertGreaterThan(pair.right, pair.left, "SSD 热区应偏右风扇")
    }

    func test_affinity_cpuGpuMemoryEqualOnBothFans() {
        for zone in [ThermalZone.cpu, .gpu, .memory] {
            let pair = FanZoneAffinity.affinity(for: zone)
            XCTAssertEqual(pair.left, pair.right, "\(zone) 双风扇等责")
        }
    }
}
