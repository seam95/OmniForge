import XCTest
import SwiftUI
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

/// sheet 呈现期失焦豁免：SwiftUI `.sheet` 以附属窗口挂载并接管 key 状态，
/// 面板 resignKey 属「内部失焦」。回归背景（2026-09-07 诊断）：卸载器点
/// 「选择 APP」后 sheet 抢 key → 面板失焦关闭 → sheet 被连带收回，弹窗与
/// 面板一起消失。豁免信号必须与真实 sheet 挂载联动（attachedSheet）。
@MainActor
final class ControlCenterPanelSheetExemptionTests: XCTestCase {

    private final class SheetProbe: ObservableObject {
        @Published var showSheet = false
    }

    private struct ProbeHost: View {
        @ObservedObject var probe: SheetProbe

        var body: some View {
            Text("HOST")
                .frame(width: 380, height: 400)
                .sheet(isPresented: $probe.showSheet) {
                    Text("SHEET").frame(width: 200, height: 120)
                }
        }
    }

    /// 真实链路：sheet 挂载后豁免信号必须翻转为 false（失焦不关闭）。
    func test_realSheetPresentation_blocksFocusLossClose() {
        let panel = ControlCenterPanelWindow(
            contentRect: NSRect(x: 100, y: 500, width: 380, height: 400)
        )
        let probe = SheetProbe()
        let controller = NSHostingController(rootView: AnyView(ProbeHost(probe: probe)))
        controller.sizingOptions = []
        panel.contentViewController = controller
        panel.orderFrontRegardless()

        XCTAssertTrue(panel.shouldCloseOnFocusLoss, "前置：无 sheet 时允许失焦关闭")

        probe.showSheet = true
        let attached = waitUntil(timeout: 1.5) { panel.attachedSheet != nil }

        XCTAssertTrue(attached, "sheet 应以附属窗口挂载（非激活环境亦可呈现）")
        XCTAssertFalse(panel.shouldCloseOnFocusLoss, "sheet 呈现期必须豁免失焦关闭")

        panel.orderOut(nil)
    }

    /// 无 sheet 的面板保持失焦关闭语义（点击面板外仍关闭）。
    func test_noSheet_closeOnFocusLossStaysAllowed() {
        let panel = ControlCenterPanelWindow(
            contentRect: NSRect(x: 100, y: 500, width: 380, height: 400)
        )
        XCTAssertNil(panel.attachedSheet)
        XCTAssertTrue(panel.shouldCloseOnFocusLoss)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
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
