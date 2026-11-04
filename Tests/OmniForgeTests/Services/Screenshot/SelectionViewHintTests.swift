import AppKit
import XCTest
@testable import OmniForge

/// 选区阶段顶部提示的可见性与位置回归。
/// 提示只在空闲、未锁定、无选区且有文案时出现；开始拖拽或进入编辑器后必须消失。
@MainActor
final class SelectionViewHintTests: XCTestCase {
    private var view: SelectionView!
    private let viewFrame = NSRect(x: 0, y: 0, width: 1000, height: 800)

    override func setUp() {
        super.setUp()
        view = SelectionView(frame: viewFrame)
        view.screenFrameProvider = { self.viewFrame }
        view.visibleFrameProvider = { NSRect(x: 0, y: 0, width: 1000, height: 775) }
    }

    override func tearDown() {
        view = nil
        super.tearDown()
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
    }

    func test_空闲态有文案时可见() {
        view.hintText = "拖动选择区域"
        XCTAssertTrue(view.isHintVisible)
    }

    func test_无文案时不可见() {
        XCTAssertFalse(view.isHintVisible)
        view.hintText = ""
        XCTAssertFalse(view.isHintVisible)
    }

    func test_开始拖拽后不可见() {
        view.hintText = "拖动选择区域"
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 100)))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 260, y: 240)))
        XCTAssertFalse(view.isHintVisible)
    }

    func test_选区锁定后不可见() {
        view.hintText = "拖动选择区域"
        view.selectionLocked = true
        XCTAssertFalse(view.isHintVisible)
    }

    func test_提示中心落在可见区顶部下方() {
        // visibleFrame 顶部 775，屏 frame 底部 0，内缩 28 → 747。
        XCTAssertEqual(
            SelectionView.hintCenterY(visibleFrameTopGlobal: 775, screenFrameMinY: 0),
            747
        )
        // 副屏 frame 底部为负值：255 - (-900) - 28 = 1127。
        XCTAssertEqual(
            SelectionView.hintCenterY(visibleFrameTopGlobal: 255, screenFrameMinY: -900),
            1127
        )
    }
}
