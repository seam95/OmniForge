import XCTest
@testable import OmniForge

/// 自管面板窗口定位纯函数（SPEC：水平居中锚点 + 屏缘 clamp + 顶贴锚点）。
final class ControlCenterPanelWindowTests: XCTestCase {
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 1384)
    private let panelSize = NSSize(width: 380, height: 558)

    private func anchor(x: CGFloat, width: CGFloat = 64) -> CGRect {
        // 菜单栏内锚点：底沿 ≈1412（可见区上方）。
        CGRect(x: x, y: 1412, width: width, height: 24)
    }

    func test_centeredAnchor_centersPanelUnderButton() {
        let frame = ControlCenterPanelWindow.panelFrame(
            anchorScreenFrame: anchor(x: 700),
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
        // 水平中心对准锚点中心。
        XCTAssertEqual(frame.midX, anchor(x: 700).midX, accuracy: 0.01)
        // 顶边 = 锚点下沿 - topGap。
        XCTAssertEqual(frame.maxY, 1412 - ControlCenterPanelWindow.topGap, accuracy: 0.01)
        XCTAssertEqual(frame.size, panelSize)
    }

    func test_rightEdgeAnchor_clampsIntoVisibleFrame() {
        let frame = ControlCenterPanelWindow.panelFrame(
            anchorScreenFrame: anchor(x: 1460),
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
        // 右缘不越出可见区（含内距）。
        XCTAssertLessThanOrEqual(
            frame.maxX,
            visibleFrame.maxX - ControlCenterPanelWindow.horizontalEdgeInset + 0.01
        )
    }

    func test_leftEdgeAnchor_clampsIntoVisibleFrame() {
        let frame = ControlCenterPanelWindow.panelFrame(
            anchorScreenFrame: anchor(x: 8),
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
        XCTAssertGreaterThanOrEqual(
            frame.minX,
            visibleFrame.minX + ControlCenterPanelWindow.horizontalEdgeInset - 0.01
        )
    }

    func test_oversizePanel_degradesToLeftAlignment() {
        // 面板宽超出可见区（极小屏）：退化为左缘对齐，不产生负宽越界。
        let tiny = CGRect(x: 0, y: 0, width: 200, height: 400)
        let frame = ControlCenterPanelWindow.panelFrame(
            anchorScreenFrame: anchor(x: 60),
            panelSize: NSSize(width: 380, height: 300),
            visibleFrame: tiny
        )
        XCTAssertEqual(frame.minX, tiny.minX + ControlCenterPanelWindow.horizontalEdgeInset, accuracy: 0.01)
    }

    func test_tallPanel_neverSinksBelowVisibleBottom() {
        // 高度超出可用空间时兜底：底边不低于可见区底。
        let frame = ControlCenterPanelWindow.panelFrame(
            anchorScreenFrame: anchor(x: 700),
            panelSize: NSSize(width: 380, height: 1600),
            visibleFrame: visibleFrame
        )
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY)
    }
}

/// 自管窗口版锚点可用高度：锚点下沿 → 可见区底，扣除顶隙与阴影余量 8。
final class StatusBarPanelAvailableHeightTests: XCTestCase {
    func test_anchorAboveVisibleFrame_returnsFullRoomBelow() {
        // 1440 屏：菜单栏锚点下沿 ≈1412（可见区上方），可见区底 0。
        let h = StatusBarController.availableHeight(
            anchorMinY: 1412,
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 1384)
        )
        XCTAssertEqual(h, 1404, accuracy: 0.01, "1412 - 0 - 8 间隙与阴影余量")
        XCTAssertGreaterThan(h, 690, "必须容纳满高面板")
    }

    func test_dockVisibleFrame_subtractsDockSpace() {
        // Dock 占位：可见区底 ~80，锚点 1412。
        let h = StatusBarController.availableHeight(
            anchorMinY: 1412,
            visibleFrame: CGRect(x: 0, y: 80, width: 1512, height: 1304)
        )
        XCTAssertEqual(h, 1324, accuracy: 0.01)
    }

    func test_tinyAvailable_clampsToZeroNeverNegative() {
        // 锚点下沿低于顶隙+阴影余量（8pt）时钳制为 0，绝不为负。
        let h = StatusBarController.availableHeight(
            anchorMinY: 4,
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
