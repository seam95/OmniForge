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

    func testXCentersItems() {
        XCTAssertEqual(ClotheslineLayout.x(index: 0, count: 1, width: 1000), 500)
        XCTAssertEqual(ClotheslineLayout.x(index: 0, count: 3, width: 1000), 500 - 174)
        XCTAssertEqual(ClotheslineLayout.x(index: 2, count: 3, width: 1000), 500 + 174)
    }

    func testCapacityClamped() {
        XCTAssertEqual(ClotheslineLayout.capacity(width: 300), 3)      // (300-200)/174 < 1 → 3
        XCTAssertEqual(ClotheslineLayout.capacity(width: 3820), 12)    // 上限
        XCTAssertEqual(ClotheslineLayout.capacity(width: 1500), 7)     // (1500-200)/174 ≈ 7.47 → 7
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
