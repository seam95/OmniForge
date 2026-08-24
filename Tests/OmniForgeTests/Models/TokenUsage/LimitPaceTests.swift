import XCTest
@testable import OmniForge

final class LimitPaceTests: XCTestCase {
    // MARK: - expectedUsedFraction

    func test_expectedUsedFraction_midWindow() {
        // 5h 窗口，剩 2.5h → 已过一半
        let fraction = LimitPace.expectedUsedFraction(
            windowSeconds: 18000,
            secondsUntilReset: 9000
        )
        XCTAssertEqual(try XCTUnwrap(fraction), 0.5, accuracy: 0.0001)
    }

    func test_expectedUsedFraction_clampsToZero() {
        XCTAssertEqual(
            LimitPace.expectedUsedFraction(windowSeconds: 18000, secondsUntilReset: 18000),
            0
        )
        // 剩得比窗口长（窗口刚重置前的边界抖动）→ 0
        XCTAssertEqual(
            LimitPace.expectedUsedFraction(windowSeconds: 18000, secondsUntilReset: 20000),
            0
        )
    }

    func test_expectedUsedFraction_clampsToOne() {
        XCTAssertEqual(
            LimitPace.expectedUsedFraction(windowSeconds: 18000, secondsUntilReset: 0),
            1
        )
        XCTAssertEqual(
            LimitPace.expectedUsedFraction(windowSeconds: 18000, secondsUntilReset: -100),
            1
        )
    }

    func test_expectedUsedFraction_invalidWindowReturnsNil() {
        XCTAssertNil(LimitPace.expectedUsedFraction(windowSeconds: 0, secondsUntilReset: 100))
        XCTAssertNil(LimitPace.expectedUsedFraction(windowSeconds: -5, secondsUntilReset: 100))
        XCTAssertNil(LimitPace.expectedUsedFraction(windowSeconds: .infinity, secondsUntilReset: 100))
        XCTAssertNil(LimitPace.expectedUsedFraction(windowSeconds: 18000, secondsUntilReset: .nan))
    }

    // MARK: - isOverPace（3pp 容差）

    func test_isOverPace_toleranceBoundary() {
        // 恰好超出 3pp 以内 → 不算超前
        XCTAssertFalse(LimitPace.isOverPace(usedFraction: 0.53, expectedFraction: 0.50))
        // 刚好等于容差边界 → 不算
        XCTAssertFalse(LimitPace.isOverPace(usedFraction: 0.53, expectedFraction: 0.50, tolerance: 0.03))
        // 超出多一点 → 超前
        XCTAssertTrue(LimitPace.isOverPace(usedFraction: 0.531, expectedFraction: 0.50))
        XCTAssertTrue(LimitPace.isOverPace(usedFraction: 0.80, expectedFraction: 0.50))
        // 落后 → 不超前
        XCTAssertFalse(LimitPace.isOverPace(usedFraction: 0.40, expectedFraction: 0.50))
    }

    // MARK: - compute（刻度 / ETA / projectedEnd）

    func test_compute_noNotchWhenUsageBelowThreshold() {
        let result = LimitPace.compute(
            usedFraction: 0.02,
            windowSeconds: 18000,
            secondsUntilReset: 9000,
            remainingMode: false
        )
        XCTAssertNil(result.pacePercent, "用量 <5% 不画刻度")
        XCTAssertFalse(result.paceOver)
    }

    func test_compute_notchAtExpectedWhenNotRemainingMode() {
        let result = LimitPace.compute(
            usedFraction: 0.50,
            windowSeconds: 18000,
            secondsUntilReset: 9000,
            remainingMode: false
        )
        XCTAssertNotNil(result.pacePercent)
        XCTAssertEqual(result.pacePercent ?? -1, 50, accuracy: 0.01)
        XCTAssertEqual(result.expectedPercent, 50)
        XCTAssertFalse(result.paceOver)
    }

    func test_compute_notchMirroredInRemainingMode() {
        let result = LimitPace.compute(
            usedFraction: 0.50,
            windowSeconds: 18000,
            secondsUntilReset: 9000,
            remainingMode: true
        )
        XCTAssertEqual(result.pacePercent ?? -1, 50, accuracy: 0.01)
    }

    func test_compute_overPaceFlagsAndProjectedEnd() {
        // 5h 窗口剩 2.5h：期望 50%；实际用 80% → 超前，预计 reset 时 160% → 耗尽分支
        let result = LimitPace.compute(
            usedFraction: 0.80,
            windowSeconds: 18000,
            secondsUntilReset: 9000,
            remainingMode: false
        )
        XCTAssertTrue(result.paceOver)
        XCTAssertNotNil(result.runsOutEta)
        XCTAssertNil(result.projectedEnd)
    }

    func test_compute_underPaceProjectedEnd() {
        // 期望 50%，实际 40% → 落后，预计 reset 时 80%
        let result = LimitPace.compute(
            usedFraction: 0.40,
            windowSeconds: 18000,
            secondsUntilReset: 9000,
            remainingMode: false
        )
        XCTAssertFalse(result.paceOver)
        XCTAssertNil(result.runsOutEta)
        XCTAssertEqual(result.projectedEnd, 80)
    }

    func test_compute_etaMatchesDurationString() {
        // 5h 窗口剩 2.5h：期望 50%；实际 90% → rate = 0.9/9000，ETA = (1-0.9)/rate
        let result = LimitPace.compute(
            usedFraction: 0.90,
            windowSeconds: 18000,
            secondsUntilReset: 9000,
            remainingMode: false
        )
        XCTAssertNotNil(result.runsOutEta)
        // rate = 0.0001 /s → (0.1) / 0.0001 = 1000s ≈ 16m40s → "16m"
        XCTAssertEqual(result.runsOutEta, "16m")
    }

    func test_compute_untrustedWindowReturnsEmpty() {
        let result = LimitPace.compute(
            usedFraction: 0.5,
            windowSeconds: 0,
            secondsUntilReset: 9000,
            remainingMode: false
        )
        XCTAssertNil(result.pacePercent)
        XCTAssertNil(result.expectedPercent)
        XCTAssertFalse(result.paceOver)
    }

    // MARK: - durationString 边界（> 24 才进位天，整 24h 显示 "24h" — 对齐 TokenTracker）

    func test_durationString_boundaries() {
        XCTAssertEqual(LimitPace.durationString(0), "0m")
        XCTAssertEqual(LimitPace.durationString(-10), "0m")
        XCTAssertEqual(LimitPace.durationString(59), "0m")
        XCTAssertEqual(LimitPace.durationString(60), "1m")
        XCTAssertEqual(LimitPace.durationString(3599), "59m")
        XCTAssertEqual(LimitPace.durationString(3600), "1h")
        XCTAssertEqual(LimitPace.durationString(86399), "23h")
        XCTAssertEqual(LimitPace.durationString(86400), "24h", "恰好 24h 不进位天")
        XCTAssertEqual(LimitPace.durationString(24 * 3600 + 3600), "1d", "超过 24h 进位天")
        XCTAssertEqual(LimitPace.durationString(2 * 86400 + 3600), "2d")
    }

    // MARK: - 投影守卫（expected > 0.02 才投影 — 对齐 TokenTracker）

    func test_compute_noProjectionWhenExpectedNearZero() {
        // 窗口刚开始（期望 ≈1%）时比例失真 → 无 ETA / projectedEnd。
        let result = LimitPace.compute(
            usedFraction: 0.05,
            windowSeconds: 18000,
            secondsUntilReset: 17820, // elapsed 180s → expected = 0.01
            remainingMode: false
        )
        XCTAssertNil(result.runsOutEta)
        XCTAssertNil(result.projectedEnd)
    }
}
