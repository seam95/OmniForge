import AppKit
import XCTest
@testable import OmniForge

/// 截图 overlay 的 ESC 键路由回归：
/// 编辑器处于文字编辑态时 ESC 放行（由 EditableTextField 的 cancelOperation
/// 仅退出输入框），不取消整个会话；非编辑态（含无编辑器）ESC 仍正常取消。
@MainActor
final class CaptureOverlayKeyRoutingTests: XCTestCase {

    // MARK: - Helpers

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        )!
    }

    /// 启动会话并嵌入真实标注编辑器（suppressesWindowDisplay 测试环境默认开，
    /// 不弹真实遮罩）。返回 controller、宿主视图与嵌入的编辑器。
    private func makeOverlayWithEditor() throws
        -> (controller: CaptureOverlayController, host: SelectionView, editor: AnnotationEditorController) {
        let controller = CaptureOverlayController()
        let host = SelectionView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
        var completions: [NSImage?] = []
        controller.startCapture { completions.append($0) }
        let image = NSImage(size: NSSize(width: 4, height: 3))
        controller.embedEditorForTesting(
            image: image,
            selectionRect: NSRect(x: 0, y: 0, width: 200, height: 150),
            selectionView: host
        )
        let editor = try XCTUnwrap(
            controller.editorControllerForTesting,
            "embedEditorForTesting 应嵌入标注编辑器"
        )
        return (controller, host, editor)
    }

    /// 切到文字工具并在画布空白处单击，让画布进入真实文字编辑态。
    private func beginTextEditing(on editor: AnnotationEditorController) throws {
        editor.selectTool(.text)
        let canvas = try XCTUnwrap(editor.canvasView, "编辑器应持有画布")
        let point = NSPoint(x: 100, y: 75)
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: point))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: point))
    }

    // MARK: - ESC 路由

    func test_escRouting_whileEditingText_yieldsEventAndKeepsSession() throws {
        let (controller, _, editor) = try makeOverlayWithEditor()
        try beginTextEditing(on: editor)
        XCTAssertTrue(editor.isEditingText, "前置条件：画布应处于文字编辑态")

        // ESC（keyCode 53）在文字编辑态应放行事件、不取消会话。
        let consumed = controller.routeEscKeyDownForTesting(keyCode: 53)

        XCTAssertFalse(consumed, "文字编辑态 ESC 应放行给 EditableTextField 的 cancelOperation")
        XCTAssertFalse(controller.isTornDownForTesting, "会话不应被取消（丢整张已标注截图）")
        XCTAssertFalse(controller.endedByUserCancel, "不应记为用户取消")
    }

    func test_escRouting_idleEditor_cancelsSession() throws {
        let (controller, _, editor) = try makeOverlayWithEditor()
        XCTAssertFalse(editor.isEditingText, "前置条件：编辑器不在文字编辑态")

        let consumed = controller.routeEscKeyDownForTesting(keyCode: 53)

        XCTAssertTrue(consumed, "非编辑态 ESC 应被消费")
        XCTAssertTrue(controller.isTornDownForTesting, "会话应取消并拆除")
        XCTAssertTrue(controller.endedByUserCancel, "应记为用户取消")
    }

    func test_escRouting_withoutEditor_cancelsSession() throws {
        let controller = CaptureOverlayController()
        controller.startCapture { _ in }

        let consumed = controller.routeEscKeyDownForTesting(keyCode: 53)

        XCTAssertTrue(consumed, "无编辑器时 ESC 应取消会话")
        XCTAssertTrue(controller.isTornDownForTesting)
    }

    func test_escRouting_nonEscKeyCode_passesThroughWithoutCancel() throws {
        let (controller, _, _) = try makeOverlayWithEditor()

        // 非 ESC 按键（如 Return，keyCode 36）必须原样放行且不触发取消。
        let consumed = controller.routeEscKeyDownForTesting(keyCode: 36)

        XCTAssertFalse(consumed, "非 ESC 按键不应被吞")
        XCTAssertFalse(controller.isTornDownForTesting, "非 ESC 按键不应取消会话")
    }

    // MARK: - 编辑器文字编辑态暴露

    func test_editor_isEditingText_reflectsTextFieldLifecycle() throws {
        let (_, _, editor) = try makeOverlayWithEditor()
        XCTAssertFalse(editor.isEditingText, "无输入框时应为 false")

        try beginTextEditing(on: editor)
        XCTAssertTrue(editor.isEditingText, "文字输入中应为 true")

        editor.canvasView?.commitActiveTextEditing()
        XCTAssertFalse(editor.isEditingText, "提交后应为 false")
    }
}
