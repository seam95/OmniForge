import AppKit
import XCTest
@testable import OmniForge

/// 截图链路窗口动画行为回归测试。
///
/// macOS 26+ 起 AppKit 对 `orderFront:`/`orderOut:` 默认附加系统级淡入淡出
/// 动画（未文档化行为变更），截图遮罩/录屏 chrome/钉图等窗口要求即时显隐，
/// 必须在建窗处显式 `animationBehavior = .none`。本套件逐类钉住该契约，
/// 防止新建窗口遗漏设置。
@MainActor
final class ScreenshotWindowAnimationBehaviorTests: XCTestCase {

    // MARK: - 遮罩层（选区截图与全屏截图共用建窗路径）

    func test_captureOverlayPanel_disablesSystemWindowAnimation() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first, "测试环境无可用屏幕")
        let controller = CaptureOverlayController(editorEnabled: true)

        let panel = controller.makeOverlayPanelForTesting(for: screen)

        XCTAssertEqual(panel.animationBehavior, .none, "遮罩面板必须禁用系统淡入淡出")
    }

    // MARK: - 录屏 chrome

    func test_recordingBorderPanel_disablesSystemWindowAnimation() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first, "测试环境无可用屏幕")

        let panel = RecordingBorderPanel(screen: screen)

        XCTAssertEqual(panel.animationBehavior, .none, "录屏边框必须禁用系统淡入淡出")
    }

    func test_recordingHUDPanel_disablesSystemWindowAnimation() {
        let panel = RecordingHUDPanel()

        XCTAssertEqual(panel.animationBehavior, .none, "录屏 HUD 必须禁用系统淡入淡出")
    }

    // MARK: - 长截图 chrome

    func test_scrollCaptureHUDWindow_disablesSystemWindowAnimation() {
        let window = ScrollCaptureHUDWindow(title: "长截图", stopTitle: "停止", onStop: {})

        XCTAssertEqual(window.animationBehavior, .none, "长截图 HUD 必须禁用系统淡入淡出")
    }

    func test_scrollPreviewWindow_disablesSystemWindowAnimation() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first, "测试环境无可用屏幕")
        // 选区收在屏幕左半区，保证右侧有 ≥224pt 空间，init? 命中 .right 分支。
        let captureRect = NSRect(
            x: screen.frame.minX + 20,
            y: screen.frame.midY - 100,
            width: 200,
            height: 200
        )

        let window = try XCTUnwrap(
            ScrollPreviewWindow(captureRect: captureRect, screen: screen),
            "右侧空间充足时预览窗必须可建"
        )

        XCTAssertEqual(window.animationBehavior, .none, "长截图预览窗必须禁用系统淡入淡出")
    }

    // MARK: - 编辑器 toast

    func test_editorInfoToastWindow_disablesSystemWindowAnimation() {
        let window = EditorInfoToastWindow()

        XCTAssertEqual(window.animationBehavior, .none, "编辑器 toast 必须禁用系统淡入淡出")
    }

    // MARK: - 钉图

    func test_pinnedScreenshotPanel_disablesSystemWindowAnimation() {
        let controller = PinnedScreenshotWindowController(
            id: UUID(),
            image: makeTestCGImage(),
            pointPixelScale: 2,
            baseResult: nil,
            pipeline: ScreenshotResultPipeline(),
            onClose: { _ in }
        )

        let panel = controller.makePanelForTesting(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        XCTAssertEqual(panel.animationBehavior, .none, "钉图面板必须禁用系统淡入淡出")
    }

    // MARK: - 工具

    private func makeTestCGImage() -> CGImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        return rep.cgImage!
    }
}
