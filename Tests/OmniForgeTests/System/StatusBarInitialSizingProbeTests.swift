import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// 首显测高路径验证：离屏 hosting view + runloop 泵等待后，
/// 自然高度与 chrome 必须就绪且 commit 出自适应总高（非固定 580）。
/// 复刻 StatusBarController.installPopoverContentIfNeeded 的真实序列。
@MainActor
final class StatusBarInitialSizingProbeTests: XCTestCase {
    func test_offscreenPump_initialMeasurementReadyAndAdaptive() {
        let state = makeStateForObservation()
        let context = ControlCenterSizingContext(backingScaleProvider: { 2 })
        context.availableTotalHeightProvider = { 1055 }

        context.beginInitialMeasurement()
        let controller = NSHostingController(
            rootView: AnyView(
                ControlCenterContainerView(state: state, sizingContext: context)
            )
        )
        controller.sizingOptions = []
        let hostingView = controller.view
        hostingView.setFrameSize(
            NSSize(width: ControlCenterContentMetrics.panelWidth, height: 2000)
        )
        hostingView.layoutSubtreeIfNeeded()

        let waitDeadline = Date().addingTimeInterval(0.4)
        while !context.hasInitialMeasurement && Date() < waitDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertTrue(
            context.hasInitialMeasurement,
            "泵 runloop 后离屏测量必须就绪（onPreferenceChange 派发不依赖 window）"
        )
        let total = context.commitInitialMeasurement()
        // 监控页自然高度 < 580 上限 → 总高必须低于固定时代 675。
        XCTAssertLessThan(total, 675, "首显总高应按自然高度收缩，实测 \(total)")
        XCTAssertGreaterThan(total, 300)
    }
}

/// 锚点可用高度计算（曾因方向写反恒 ≤0 导致全链路降级固定高度）。
final class StatusBarAvailableHeightTests: XCTestCase {
    func test_anchorAboveVisibleFrame_returnsFullRoomBelow() {
        // 1440 屏：菜单栏锚点下沿 ≈1412（可见区上方），可见区底 0。
        let h = StatusBarController.availableHeight(
            anchorMinY: 1412,
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 1384)
        )
        XCTAssertEqual(h, 1382, accuracy: 0.01, "1412 - 0 - 30 装饰余量")
        XCTAssertGreaterThan(h, 690, "必须容纳满高面板")
    }

    func test_dockVisibleFrame_subtractsDockSpace() {
        // Dock 占位：可见区底 ~80，锚点 1412。
        let h = StatusBarController.availableHeight(
            anchorMinY: 1412,
            visibleFrame: CGRect(x: 0, y: 80, width: 1512, height: 1304)
        )
        XCTAssertEqual(h, 1302, accuracy: 0.01)
    }

    func test_tinyAvailable_clampsToZeroNeverNegative() {
        let h = StatusBarController.availableHeight(
            anchorMinY: 10,
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 1384)
        )
        XCTAssertEqual(h, 0)
    }

    func test_wrongDirectionWouldBeRejected_guardAgainstRegression() {
        // 回归防线：旧错误方向（visibleFrame.maxY - anchor.minY）在本场景
        // 产生负值；正确实现必须为正。
        let anchorMinY: CGFloat = 1412
        let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 1384)
        let wrongDirection = visibleFrame.maxY - anchorMinY // -28
        XCTAssertLessThan(wrongDirection, 0, "场景前提：锚点在可见区上方")
        XCTAssertGreaterThan(
            StatusBarController.availableHeight(anchorMinY: anchorMinY, visibleFrame: visibleFrame),
            0
        )
    }
}
