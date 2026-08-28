import XCTest
@testable import OmniForge

@MainActor
final class StickyNoteScrollerTests: XCTestCase {

    /// 安装后：接管竖向滚动条、overlay 风格、内容不溢出时自动隐藏（防回归突兀白条）。
    func test_install_configuresAutohidingOverlayVerticalScroller() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        let scroller = StickyNoteScroller.install(on: scrollView)

        XCTAssertIdentical(scrollView.verticalScroller, scroller)
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertTrue(scrollView.autohidesScrollers)
        XCTAssertEqual(scroller.scrollerStyle, .overlay)
        XCTAssertEqual(scroller.controlSize, .small)
    }

    /// knob 颜色可被注入更新（色板/深浅色切换路径）。
    func test_knobColor_isAssignable() {
        let scroller = StickyNoteScroller()
        let color = NSColor.red.withAlphaComponent(0.32)

        scroller.knobColor = color

        XCTAssertEqual(scroller.knobColor, color)
    }
}
