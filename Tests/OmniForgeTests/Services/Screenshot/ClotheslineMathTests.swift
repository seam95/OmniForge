// Tests/OmniForgeTests/Services/Screenshot/ClotheslineMathTests.swift
import XCTest
@testable import OmniForge

final class ClotheslineMathTests: XCTestCase {
    func testRopeIsParabolaPeakingAtCenter() {
        XCTAssertEqual(ClotheslineLayout.ropeY(x: 0, width: 1000), 10)
        XCTAssertEqual(ClotheslineLayout.ropeY(x: 1000, width: 1000), 10)
        let mid = ClotheslineLayout.ropeY(x: 500, width: 1000)
        let sag = ClotheslineLayout.sag(width: 1000)   // min(30, 18) = 18
        XCTAssertEqual(sag, 18)
        XCTAssertEqual(mid, 10 + 4 * sag * 0.25)       // 顶点 = ropeTop + sag
    }

    func testPhotoXFlanksCenterGapSymmetricallyForEvenCounts() {
        // 偶数张：以中央缺口完全对称，最内两张距缺口各半格
        let gap = ClotheslineLayout.centerGap
        let left = ClotheslineLayout.photoX(displayIndex: 0, count: 2, width: 1000)
        let right = ClotheslineLayout.photoX(displayIndex: 1, count: 2, width: 1000)
        XCTAssertEqual(left, 500 - gap / 2 - ClotheslineLayout.spacing / 2)
        XCTAssertEqual(right, 500 + gap / 2 + ClotheslineLayout.spacing / 2)
        XCTAssertEqual(500 - left, right - 500)   // 对称

        // 四张：两侧各两张，逐格外扩
        let xs = (0..<4).map { ClotheslineLayout.photoX(displayIndex: $0, count: 4, width: 1000) }
        XCTAssertEqual(xs[1], xs[0] + ClotheslineLayout.spacing)         // 左半由内向外
        XCTAssertEqual(xs[2], 500 + gap / 2 + ClotheslineLayout.spacing / 2)
        XCTAssertEqual(xs[3], xs[2] + ClotheslineLayout.spacing)
        XCTAssertEqual(500 - xs[0], xs[3] - 500)                        // 整体对称
    }

    func testPhotoXOddCountPutsExtraOnRight() {
        // 奇数张：右半多一张（左 ceil/2、右 floor/2 之外的归属固定给右侧）
        let xs = (0..<3).map { ClotheslineLayout.photoX(displayIndex: $0, count: 3, width: 1000) }
        XCTAssertEqual(xs[0], 500 - ClotheslineLayout.centerGap / 2 - ClotheslineLayout.spacing / 2)
        XCTAssertEqual(xs[1], 500 + ClotheslineLayout.centerGap / 2 + ClotheslineLayout.spacing / 2)
        XCTAssertEqual(xs[2], xs[1] + ClotheslineLayout.spacing)
    }

    func testPhotoXNeverOccupiesCenter() {
        // 任何数量下，卡片都不落在扫帚位（中央 ±gap/2 内无卡片中心）
        for count in 1...12 {
            for i in 0..<count {
                let x = ClotheslineLayout.photoX(displayIndex: i, count: count, width: 1440)
                XCTAssertFalse(abs(x - 720) < ClotheslineLayout.centerGap / 2 + 1,
                               "count=\(count) idx=\(i) x=\(x) 侵入了扫帚位")
            }
        }
    }

    func testCapacityClamped() {
        XCTAssertEqual(ClotheslineLayout.capacity(width: 300), 3)      // (300-200)/174 < 1 → 3
        XCTAssertEqual(ClotheslineLayout.capacity(width: 3820), 12)    // 上限
        XCTAssertEqual(ClotheslineLayout.capacity(width: 1500), 7)     // (1500-200)/174 ≈ 7.47 → 7
    }

    func testVisibleAndHiddenCounts() {
        // 总数少于屏宽容量：全可见，无隐藏
        XCTAssertEqual(ClotheslineLayout.visibleCount(total: 5, width: 1500), 5)
        XCTAssertEqual(ClotheslineLayout.hiddenCount(total: 5, width: 1500), 0)
        // 总数超出：展示最新的屏宽容量段
        XCTAssertEqual(ClotheslineLayout.visibleCount(total: 10, width: 1500), 7)
        XCTAssertEqual(ClotheslineLayout.hiddenCount(total: 10, width: 1500), 3)
        // 总数 0
        XCTAssertEqual(ClotheslineLayout.visibleCount(total: 0, width: 1500), 0)
        XCTAssertEqual(ClotheslineLayout.hiddenCount(total: 0, width: 1500), 0)
    }

    func testEaseInOutCubicEndpoints() {
        XCTAssertEqual(CaptureFlightMath.easeInOutCubic(0), 0)
        XCTAssertEqual(CaptureFlightMath.easeInOutCubic(1), 1, accuracy: 1e-9)
        XCTAssertEqual(CaptureFlightMath.easeInOutCubic(0.5), 0.5, accuracy: 1e-9)
    }

    func testSmoothstepWindow() {
        XCTAssertEqual(CaptureFlightMath.smoothstep(0.2, 0.35, 1), 0)
        XCTAssertEqual(CaptureFlightMath.smoothstep(1, 0.35, 1), 1)
        // 窗口 [0.35, 1] 的中点是 0.675（非 0.5）：smoothstep 曲线中心对称，中点值恒为 0.5。
        XCTAssertEqual(CaptureFlightMath.smoothstep(0.675, 0.35, 1), 0.5, accuracy: 1e-9)
    }

    func testFlightStateEndpointsAndArc() {
        let from = CGRect(x: 0, y: 0, width: 400, height: 300)
        let to = CGRect(x: 500, y: 700, width: 150, height: 120)
        let start = CaptureFlightMath.flightState(k: 0, from: from, to: to, tilt: 2, arc: 30)
        XCTAssertEqual(start.bounds.width, 400); XCTAssertEqual(start.bounds.height, 300)
        XCTAssertEqual(start.chrome, 0)
        let end = CaptureFlightMath.flightState(k: 1, from: from, to: to, tilt: 2, arc: 30)
        XCTAssertEqual(end.bounds.width, 150); XCTAssertEqual(end.bounds.height, 120)
        XCTAssertEqual(end.chrome, 1)
        // 中点弧线抬高：position.y > 两端线性插值（sin(π·k)=1）
        let mid = CaptureFlightMath.flightState(k: 0.5, from: from, to: to, tilt: 2, arc: 30)
        let lerpY = (from.maxY + to.maxY) / 2
        XCTAssertEqual(mid.position.y, lerpY + 30, accuracy: 0.5)
    }

    func testFallStateProgression() {
        let s = CaptureFlightMath.fallState(k: 1, tilt: 2)
        XCTAssertEqual(s.offset, 520)
        XCTAssertEqual(s.opacity, 0)
        let half = CaptureFlightMath.fallState(k: 0.5, tilt: 2)
        XCTAssertEqual(half.offset, 520 * 0.125, accuracy: 0.5)   // cubic ease-in
        XCTAssertGreaterThan(half.opacity, 0)
        XCTAssertLessThan(half.opacity, 1)
    }
}
