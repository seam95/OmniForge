import AppKit
import XCTest
@testable import OmniForge

final class WindowDragHostingViewTests: XCTestCase {
    func test_dragThreshold_ignoresSubThresholdJitter() {
        let start = NSPoint(x: 100, y: 100)

        // 触摸板单击常见 3-5pt 抖动不应触发拖动
        XCTAssertFalse(
            WindowDragHostingView.dragExceedsThreshold(from: start, to: NSPoint(x: 103, y: 104))
        )
        // 阈值边界内侧（7pt 水平位移）
        XCTAssertFalse(
            WindowDragHostingView.dragExceedsThreshold(from: start, to: NSPoint(x: 107, y: 100))
        )
    }

    func test_dragThreshold_acceptsThresholdAndBeyond() {
        let start = NSPoint(x: 100, y: 100)

        // 恰好 8pt（含边界）
        XCTAssertTrue(
            WindowDragHostingView.dragExceedsThreshold(from: start, to: NSPoint(x: 108, y: 100))
        )
        // 对角线合成位移越阈
        XCTAssertTrue(
            WindowDragHostingView.dragExceedsThreshold(from: start, to: NSPoint(x: 106, y: 106))
        )
        // 反方向同样按距离判定
        XCTAssertTrue(
            WindowDragHostingView.dragExceedsThreshold(from: start, to: NSPoint(x: 91, y: 100))
        )
    }
}
