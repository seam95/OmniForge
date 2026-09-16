import XCTest
@testable import OmniForge

final class StickyNoteGeometryTests: XCTestCase {
    /// 1920×1080 主屏可视区（AppKit 全局坐标，原点左下）。
    private let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1045)
    /// 主屏右侧 1080×1920 副屏。
    private let sideScreen = CGRect(x: 1920, y: 0, width: 1080, height: 1920)
    private var screens: [CGRect] { [mainScreen, sideScreen] }

    func test_frameAtMouse_centersFrameOnMouse() {
        let mouse = CGPoint(x: 960, y: 522)
        let frame = StickyNoteGeometry.frameAtMouse(
            mouse,
            size: StickyNoteGeometry.defaultSize,
            visibleScreens: screens
        )

        XCTAssertEqual(frame.midX, mouse.x, accuracy: 0.001)
        XCTAssertEqual(frame.midY, mouse.y, accuracy: 0.001)
        XCTAssertEqual(frame.size, StickyNoteGeometry.defaultSize)
    }

    func test_frameAtMouse_nearScreenEdge_clampsFullyInsideScreen() {
        // 鼠标贴主屏右上角：以鼠标为中心的 frame 会越界，须整体钳回可视区
        let mouse = CGPoint(x: mainScreen.maxX - 4, y: mainScreen.maxY - 4)
        let frame = StickyNoteGeometry.frameAtMouse(
            mouse,
            size: StickyNoteGeometry.defaultSize,
            visibleScreens: screens
        )

        XCTAssertTrue(StickyNoteGeometry.isFullyContained(frame, in: [mainScreen]))
    }

    func test_frameAtMouse_onSideScreen_landsOnSideScreen() {
        let mouse = CGPoint(x: sideScreen.midX, y: sideScreen.midY)
        let frame = StickyNoteGeometry.frameAtMouse(
            mouse,
            size: StickyNoteGeometry.defaultSize,
            visibleScreens: screens
        )

        XCTAssertTrue(StickyNoteGeometry.isFullyContained(frame, in: [sideScreen]))
        XCTAssertEqual(frame.midX, mouse.x, accuracy: 0.001)
        XCTAssertEqual(frame.midY, mouse.y, accuracy: 0.001)
    }

    func test_frameAtMouse_withoutMouseLocation_fallsBackToDefault() {
        let frame = StickyNoteGeometry.frameAtMouse(
            nil,
            size: StickyNoteGeometry.defaultSize,
            visibleScreens: screens
        )

        XCTAssertEqual(frame, StickyNoteGeometry.defaultFrame(on: screens))
    }

    func test_frameAtMouse_mouseOffAllScreens_fallsBackToDefault() {
        let offScreens = CGPoint(x: -500, y: -500)
        let frame = StickyNoteGeometry.frameAtMouse(
            offScreens,
            size: StickyNoteGeometry.defaultSize,
            visibleScreens: screens
        )

        XCTAssertEqual(frame, StickyNoteGeometry.defaultFrame(on: screens))
    }

    func test_frameAtMouse_sizeExceedsScreen_fitsInsideScreen() {
        let mouse = CGPoint(x: mainScreen.midX, y: mainScreen.midY)
        let oversized = CGSize(width: 3000, height: 2000)
        let frame = StickyNoteGeometry.frameAtMouse(mouse, size: oversized, visibleScreens: [mainScreen])

        XCTAssertEqual(frame.width, mainScreen.width, accuracy: 0.001)
        XCTAssertEqual(frame.height, mainScreen.height, accuracy: 0.001)
        XCTAssertTrue(StickyNoteGeometry.isFullyContained(frame, in: [mainScreen]))
    }

    func test_frameAtMouse_usesRememberedSize() {
        let mouse = CGPoint(x: 960, y: 522)
        let remembered = CGSize(width: 480, height: 360)
        let frame = StickyNoteGeometry.frameAtMouse(mouse, size: remembered, visibleScreens: screens)

        XCTAssertEqual(frame.size, remembered)
        XCTAssertEqual(frame.midX, mouse.x, accuracy: 0.001)
    }

    func test_defaultFrame_withoutScreens_returnsZeroOriginDefaultSize() {
        let frame = StickyNoteGeometry.defaultFrame(on: [])
        XCTAssertEqual(frame, CGRect(origin: .zero, size: StickyNoteGeometry.defaultSize))
    }

    func test_defaultFrame_withCustomSize_usesGivenSizeAtTopLeft() {
        let custom = CGSize(width: 480, height: 360)
        let frame = StickyNoteGeometry.defaultFrame(size: custom, on: screens)

        XCTAssertEqual(frame.size, custom)
        XCTAssertEqual(frame.minX, mainScreen.minX + 16, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, mainScreen.maxY - 16, accuracy: 0.001)
    }

    func test_awakenFrame_centersHorizontallyBelowScreenTop() {
        let size = CGSize(width: 280, height: 200)
        let frame = StickyNoteGeometry.awakenFrame(size: size, on: mainScreen)

        XCTAssertEqual(frame.midX, mainScreen.midX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, mainScreen.maxY - 16, accuracy: 0.001)
        XCTAssertEqual(frame.size, size)
    }

    func test_awakenFrame_tinyScreen_keepsMinimumSize() {
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 220)
        let frame = StickyNoteGeometry.awakenFrame(size: StickyNoteGeometry.defaultSize, on: tiny)

        // 屏幕宽 300 < 默认宽 320：宽度钳到 300；高度 260 > 220 也钳到 220 后仍取最小值约束
        XCTAssertEqual(frame.width, 300, accuracy: 0.001)
        XCTAssertEqual(frame.height, 220, accuracy: 0.001)
    }

    func test_clampedSize_enforcesMinimum() {
        let clamped = StickyNoteGeometry.clampedSize(CGSize(width: 100, height: 50))
        XCTAssertEqual(clamped, StickyNoteGeometry.minimumSize)
    }

    func test_collapsedFrame_alignsTopEdgeAndShrinksHeight() {
        let expanded = CGRect(x: 100, y: 600, width: 320, height: 260)

        let collapsed = StickyNoteGeometry.collapsedFrame(expanded: expanded)

        // 顶边对齐原地收缩：只压高度，视觉位置不动
        XCTAssertEqual(collapsed.minX, expanded.minX, accuracy: 0.001)
        XCTAssertEqual(collapsed.maxY, expanded.maxY, accuracy: 0.001)
        XCTAssertEqual(collapsed.width, expanded.width, accuracy: 0.001)
        XCTAssertEqual(collapsed.height, StickyNoteGeometry.collapsedHeight, accuracy: 0.001)
    }

    func test_expandedFrame_restoresSizeFromDraggedCollapsedBar() {
        // 折叠条被拖到新位置后展开：顶边对齐反推，尺寸取展开态真源
        let expandedSize = CGSize(width: 320, height: 260)
        let draggedBar = CGRect(x: 480, y: 200, width: 320, height: StickyNoteGeometry.collapsedHeight)

        let expanded = StickyNoteGeometry.expandedFrame(fromCollapsed: draggedBar, expandedSize: expandedSize)

        XCTAssertEqual(expanded.minX, 480, accuracy: 0.001)
        XCTAssertEqual(expanded.maxY, draggedBar.maxY, accuracy: 0.001)
        XCTAssertEqual(expanded.size, expandedSize)
    }

    func test_collapsedAndExpandedFrames_areMutuallyInverse() {
        let original = CGRect(x: -50, y: 300, width: 280, height: 400)

        let roundTrip = StickyNoteGeometry.expandedFrame(
            fromCollapsed: StickyNoteGeometry.collapsedFrame(expanded: original),
            expandedSize: original.size
        )

        XCTAssertEqual(roundTrip, original)
    }

    func test_isFullyContained_boundaryEqualsScreen_counts() {
        let frame = mainScreen
        XCTAssertTrue(StickyNoteGeometry.isFullyContained(frame, in: screens))
    }
}
