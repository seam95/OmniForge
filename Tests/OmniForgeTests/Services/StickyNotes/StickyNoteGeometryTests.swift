import XCTest
@testable import OmniForge

final class StickyNoteGeometryTests: XCTestCase {
    /// 1920×1080 主屏可视区（AppKit 全局坐标，原点左下）。
    private let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1045)
    /// 主屏右侧 1080×1920 副屏。
    private let sideScreen = CGRect(x: 1920, y: 0, width: 1080, height: 1920)
    private var screens: [CGRect] { [mainScreen, sideScreen] }

    func test_cascadeFrame_withoutHistory_returnsMainScreenDefaultPosition() {
        let frame = StickyNoteGeometry.cascadeFrame(lastCreatedFrame: nil, visibleScreens: screens)

        XCTAssertEqual(frame.width, 320)
        XCTAssertEqual(frame.height, 260)
        // 主屏左上角，留 16pt 边距
        XCTAssertEqual(frame.minX, mainScreen.minX + 16, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, mainScreen.maxY - 16, accuracy: 0.001)
    }

    func test_cascadeFrame_withHistory_offsetsVisuallyDownRight() {
        let last = CGRect(x: 100, y: 600, width: 320, height: 260)
        let frame = StickyNoteGeometry.cascadeFrame(lastCreatedFrame: last, visibleScreens: screens)

        // AppKit y 向上为正：视觉右下 = x+28、y-28
        XCTAssertEqual(frame.origin.x, 128, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 572, accuracy: 0.001)
        XCTAssertEqual(frame.size, last.size)
    }

    func test_cascadeFrame_whenCandidateExitsScreens_fallsBackToDefault() {
        // 级联后右下角越出主屏右缘
        let last = CGRect(x: 1650, y: 810, width: 320, height: 260)
        let frame = StickyNoteGeometry.cascadeFrame(lastCreatedFrame: last, visibleScreens: screens)

        XCTAssertEqual(frame, StickyNoteGeometry.defaultFrame(on: screens))
    }

    func test_cascadeFrame_whenCandidateFitsSideScreen_usesCandidate() {
        // 最近便签位于副屏，级联后仍完整落在副屏内
        let last = CGRect(x: 1950, y: 200, width: 320, height: 260)
        let frame = StickyNoteGeometry.cascadeFrame(lastCreatedFrame: last, visibleScreens: screens)

        XCTAssertEqual(frame.origin.x, 1978, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 172, accuracy: 0.001)
    }

    func test_defaultFrame_withoutScreens_returnsZeroOriginDefaultSize() {
        let frame = StickyNoteGeometry.defaultFrame(on: [])
        XCTAssertEqual(frame, CGRect(origin: .zero, size: StickyNoteGeometry.defaultSize))
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
