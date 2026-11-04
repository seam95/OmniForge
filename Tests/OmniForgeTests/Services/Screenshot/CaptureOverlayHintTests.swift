import AppKit
import XCTest
@testable import OmniForge

/// 遮罩控制器顶部提示回归：
/// 文案随会话用途切换；只有鼠标所在屏持有提示，切换后旧屏清空；tearDown 重置用途。
@MainActor
final class CaptureOverlayHintTests: XCTestCase {
    private func makeView() -> SelectionView {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let view = SelectionView(frame: frame)
        view.screenFrameProvider = { frame }
        view.visibleFrameProvider = { frame }
        return view
    }

    func test_文案按会话用途映射() {
        let strings = Strings.zhHans
        XCTAssertEqual(
            CaptureOverlayController.hintText(for: .screenshot, strings: strings),
            strings.screenshotSelectionHint
        )
        XCTAssertEqual(
            CaptureOverlayController.hintText(for: .recording, strings: strings),
            strings.screenshotSelectionHintRecording
        )
    }

    func test_仅目标屏显示提示且切换后旧屏清空() {
        let controller = CaptureOverlayController(stringsProvider: { .zhHans })
        let first = makeView()
        let second = makeView()
        controller.registerSelectionViewsForTesting([first, second])

        controller.applyHint(to: first)
        XCTAssertTrue(first.isHintVisible)
        XCTAssertFalse(second.isHintVisible)

        controller.applyHint(to: second)
        XCTAssertFalse(first.isHintVisible)
        XCTAssertTrue(second.isHintVisible)
    }

    func test_录制用途注入录制文案() {
        let controller = CaptureOverlayController(stringsProvider: { .zhHans })
        controller.selectionPurpose = .recording
        let view = makeView()
        controller.registerSelectionViewsForTesting([view])

        controller.applyHint(to: view)
        XCTAssertEqual(view.hintText, Strings.zhHans.screenshotSelectionHintRecording)
    }

    func test_清除提示后不可见() {
        let controller = CaptureOverlayController(stringsProvider: { .zhHans })
        let view = makeView()
        controller.registerSelectionViewsForTesting([view])

        controller.applyHint(to: view)
        XCTAssertTrue(view.isHintVisible)

        controller.applyHint(to: nil)
        XCTAssertFalse(view.isHintVisible)
    }

    func test_tearDown后会话用途重置为截图() {
        let controller = CaptureOverlayController(stringsProvider: { .zhHans })
        controller.selectionPurpose = .recording
        controller.tearDown()
        XCTAssertEqual(controller.selectionPurpose, .screenshot)
    }
}
