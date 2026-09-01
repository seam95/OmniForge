import AppKit
import XCTest
@testable import OmniForge

/// 移动手柄交互与移动模式切换回归：
/// 原地点击进入/退出移动模式（工具栏高亮 + 无标注工具），按住拖动仍移动选区。
@MainActor
final class AnnotationEditorMoveModeTests: XCTestCase {

    // MARK: - 手柄级

    private func makeHandle() -> MoveSelectionDragHandle {
        let toolbar = AnnotationToolbarView(
            items: AnnotationToolbarLayout.primary,
            orientation: .horizontal
        )
        let handle = toolbar.subviews.compactMap { $0 as? MoveSelectionDragHandle }.first
        return handle ?? MoveSelectionDragHandle(
            frame: NSRect(x: 0, y: 0, width: 32, height: 32),
            symbolName: "arrow.up.and.down.and.arrow.left.and.right"
        )
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        )!
    }

    func test_handle_stationaryPress_firesClickToggle() {
        let handle = makeHandle()
        var clickCount = 0
        var dragStartCount = 0
        handle.onClick = { clickCount += 1 }
        handle.onDragStart = { dragStartCount += 1 }

        let point = NSPoint(x: 16, y: 16)
        handle.mouseDown(with: mouseEvent(.leftMouseDown, at: point))
        handle.mouseUp(with: mouseEvent(.leftMouseUp, at: point))

        XCTAssertEqual(clickCount, 1, "原地点击应触发移动模式切换")
        XCTAssertEqual(dragStartCount, 1, "按下仍会触发拖动开始（无位移即无移动）")
    }

    func test_handle_drag_firesDragCallbacks_notClick() {
        let handle = makeHandle()
        var clickCount = 0
        var dragDeltas: [CGSize] = []
        handle.onClick = { clickCount += 1 }
        handle.onDrag = { dragDeltas.append($0) }

        handle.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 5, y: 5)))
        handle.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 40, y: 12)))
        handle.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 40, y: 12)))

        XCTAssertEqual(clickCount, 0, "明显位移不应触发点击切换")
        XCTAssertEqual(dragDeltas.count, 1, "拖动应触发 onDrag")
        XCTAssertEqual(dragDeltas[0].width, 35, accuracy: 0.5)
    }

    func test_toolbar_setMoveModeActive_syncsHandleHighlight() {
        let toolbar = AnnotationToolbarView(
            items: AnnotationToolbarLayout.primary,
            orientation: .horizontal
        )
        let handle = toolbar.subviews.compactMap { $0 as? MoveSelectionDragHandle }.first
        XCTAssertNotNil(handle, "工具栏应包含移动手柄")

        toolbar.setMoveModeActive(true)
        XCTAssertTrue(handle?.isModeActive ?? false)
        toolbar.setMoveModeActive(false)
        XCTAssertFalse(handle?.isModeActive ?? true)
    }

    // MARK: - 控制器级

    private func makeEditor() throws -> (SelectionView, AnnotationEditorController, MoveSelectionDragHandle) {
        let host = SelectionView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
        let editor = AnnotationEditorController(
            baseImage: NSImage(size: NSSize(width: 200, height: 150)),
            document: AnnotationDocument(),
            resultRunner: FakeScreenshotResultRunner(),
            makeResult: { _ in nil },
            onComplete: { _ in }
        )
        editor.show(in: host, selectionRect: NSRect(x: 0, y: 0, width: 200, height: 150))
        let toolbar = host.subviews.compactMap { $0 as? AnnotationToolbarView }.first
        let handle = try XCTUnwrap(
            toolbar?.subviews.compactMap { $0 as? MoveSelectionDragHandle }.first,
            "编辑器工具栏应包含移动手柄"
        )
        return (host, editor, handle)
    }

    func test_clickHandle_whileToolActive_entersMoveMode() throws {
        let (_, editor, handle) = try makeEditor()
        defer { editor.close() }

        editor.selectTool(.pen)
        XCTAssertEqual(editor.activeTool, .pen)

        handle.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 16, y: 16)))
        handle.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 16, y: 16)))

        XCTAssertEqual(editor.activeTool, .none, "进入移动模式应退出当前标注工具")
        let canvasTool = try XCTUnwrap(editor.canvasView?.activeTool)
        XCTAssertEqual(canvasTool, EditTool.none)
        XCTAssertTrue(handle.isModeActive, "移动模式激活时手柄应高亮")
    }

    func test_clickHandleAgain_exitsMoveMode() throws {
        let (_, editor, handle) = try makeEditor()
        defer { editor.close() }

        handle.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 16, y: 16)))
        handle.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 16, y: 16)))
        XCTAssertTrue(handle.isModeActive)

        handle.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 16, y: 16)))
        handle.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 16, y: 16)))

        XCTAssertFalse(handle.isModeActive, "再次点击应退出移动模式")
        XCTAssertEqual(editor.activeTool, .none)
    }

    func test_selectingTool_clearsMoveModeHighlight() throws {
        let (_, editor, handle) = try makeEditor()
        defer { editor.close() }

        handle.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 16, y: 16)))
        handle.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 16, y: 16)))
        XCTAssertTrue(handle.isModeActive)

        editor.selectTool(.rectangle)

        XCTAssertFalse(handle.isModeActive, "选择其他标注工具应清除移动模式高亮")
        XCTAssertEqual(editor.activeTool, .rectangle)
    }
}
