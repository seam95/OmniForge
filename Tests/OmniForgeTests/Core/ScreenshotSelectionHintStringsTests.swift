import XCTest
@testable import OmniForge

/// 选区阶段顶部操作提示文案回归：
/// 截图与录制两个入口各有一套文案，中英文都必须提供且互不重复。
final class ScreenshotSelectionHintStringsTests: XCTestCase {
    func test_截图提示中英文均已提供() {
        XCTAssertEqual(
            Strings.zhHans.screenshotSelectionHint,
            "拖动选择区域 · 点击窗口可选整窗 · ESC 取消"
        )
        XCTAssertEqual(
            Strings.en.screenshotSelectionHint,
            "Drag to select · Click a window to snap · ESC to cancel"
        )
    }

    func test_录制提示中英文均已提供且与截图提示不同() {
        let zh = Strings.zhHans
        let en = Strings.en
        XCTAssertEqual(
            zh.screenshotSelectionHintRecording,
            "拖动选择录制区域 · 点击窗口可选整窗 · ESC 取消"
        )
        XCTAssertEqual(
            en.screenshotSelectionHintRecording,
            "Drag to select the recording area · Click a window to snap · ESC to cancel"
        )
        XCTAssertNotEqual(zh.screenshotSelectionHint, zh.screenshotSelectionHintRecording)
        XCTAssertNotEqual(en.screenshotSelectionHint, en.screenshotSelectionHintRecording)
    }
}
