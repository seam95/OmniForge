import AppKit
import XCTest
@testable import OmniForge

/// 多屏截图编辑器交互禁用回归测试。
///
/// 复现场景：双屏（A 为主屏在上，B 为副屏在下），全能截图后宿主屏 A 完成选区
/// 进入编辑器。此时在副屏 B 上点击，原本会经 selectionDidComplete →
/// applySelectionChange 用 A 屏 frame 翻转 B 屏局部坐标，污染宿主屏编辑器
/// captureRect 并撑大画布，导致 A 屏底图被拉扯。
///
/// 修复：编辑器嵌入宿主屏后，其余屏 SelectionView 的 selectionInteractionEnabled
/// 置 false，mouseDown 直接 return（见 SelectionView.mouseDown 首行 guard）。
@MainActor
final class CaptureOverlayMultiScreenTests: XCTestCase {
    func test_editorEmbedPassesChineseTextToolLabels() {
        let controller = CaptureOverlayController(
            editorEnabled: true,
            stringsProvider: { .zhHans }
        )
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))

        _ = controller.embedEditorForTesting(
            image: NSImage(size: NSSize(width: 100, height: 80)),
            selectionRect: NSRect(x: 50, y: 50, width: 200, height: 150),
            selectionView: view
        )

        XCTAssertEqual(controller.editorStringsForTesting?.annotationTextOutline, "描边")
        XCTAssertEqual(controller.editorStringsForTesting?.annotationTextFill, "背景填充")
        XCTAssertEqual(Strings.en.annotationTextOutline, "Outline")
        XCTAssertEqual(Strings.en.annotationTextFill, "Fill")

        controller.tearDown()
    }

    func test_editorEmbedDisablesInteractionOnOtherScreens() {
        let controller = CaptureOverlayController(editorEnabled: true)

        let viewA = SelectionView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        let viewB = SelectionView(frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        viewA.selectionInteractionEnabled = true
        viewB.selectionInteractionEnabled = true

        // 把两块屏的 view 注册进 controller（绕过真实 NSScreen.screens）。
        controller.registerSelectionViewsForTesting([viewA, viewB])

        // 在宿主屏 A 完成选区 → 嵌入编辑器。
        let image = NSImage(size: NSSize(width: 100, height: 80))
        let hostView = controller.embedEditorForTesting(
            image: image,
            selectionRect: NSRect(x: 50, y: 50, width: 200, height: 150),
            selectionView: viewA,
            captureRect: CGRect(x: 50, y: 600, width: 200, height: 150)
        )

        // 宿主屏仍是 viewA，且其交互保持开启（编辑器态需拖动/缩放选区）。
        XCTAssertTrue(hostView === viewA, "编辑器应嵌入触发选区的宿主屏 view")
        XCTAssertTrue(viewA.selectionInteractionEnabled, "宿主屏交互必须保持开启")

        // 关键断言：副屏 B 的选区交互必须被禁用。
        XCTAssertFalse(
            viewB.selectionInteractionEnabled,
            "编辑器嵌入宿主屏后，副屏交互必须禁用，否则跨屏点击会污染宿主屏编辑器几何"
        )

        controller.tearDown()
    }

    func test_nonHostScreenClickDoesNotComplete_afterEditorEmbed() {
        let controller = CaptureOverlayController(editorEnabled: true)

        let viewA = SelectionView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        let viewB = SelectionView(frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        viewB.delegate = FailingSelectionDelegate()
        viewB.selectionInteractionEnabled = true

        controller.registerSelectionViewsForTesting([viewA, viewB])

        let image = NSImage(size: NSSize(width: 100, height: 80))
        _ = controller.embedEditorForTesting(
            image: image,
            selectionRect: NSRect(x: 50, y: 50, width: 200, height: 150),
            selectionView: viewA,
            captureRect: CGRect(x: 50, y: 600, width: 200, height: 150)
        )

        // 副屏 B 上模拟点击（事件坐标在 B 屏局部坐标系内）。
        let down = makeMouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 100), eventNumber: 1)
        let up = makeMouseEvent(.leftMouseUp, at: NSPoint(x: 100, y: 100), eventNumber: 2)

        // selectionInteractionEnabled=false 时 mouseDown 必须 early-return，不改变任何状态。
        viewB.mouseDown(with: down)
        viewB.mouseUp(with: up)
        XCTAssertNil(viewB.currentSelectionRect, "副屏禁用后点击不得建立选区")

        controller.tearDown()
    }

    /// 副屏残留的 hover 高亮（鼠标移向副屏时由路由器设置）必须在编辑器嵌入后清除。
    /// 否则 draw 的 hover 分支不受 selectionInteractionEnabled 控制，会持续显示
    /// 绿色边框，视觉上与选区高亮混淆（"两个选区都高亮"回归）。
    func test_editorEmbedClearsHoverResidueOnOtherScreens() {
        let controller = CaptureOverlayController(editorEnabled: true)

        let viewA = SelectionView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        let viewB = SelectionView(frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        // 模拟鼠标移向副屏 B 时路由器设置的 hover 残留。
        viewB.setHoverForTesting(NSRect(x: 100, y: 100, width: 200, height: 150))
        XCTAssertTrue(viewB.hasHoverForTesting, "前置：副屏应持有 hover 残留")

        controller.registerSelectionViewsForTesting([viewA, viewB])

        let image = NSImage(size: NSSize(width: 100, height: 80))
        _ = controller.embedEditorForTesting(
            image: image,
            selectionRect: NSRect(x: 50, y: 50, width: 200, height: 150),
            selectionView: viewA,
            captureRect: CGRect(x: 50, y: 600, width: 200, height: 150)
        )

        XCTAssertFalse(
            viewB.hasHoverForTesting,
            "编辑器嵌入宿主屏后，副屏残留的 hover 高亮必须被清除"
        )

        controller.tearDown()
    }

    // MARK: - 选区像素对齐（框选截图偏移/模糊回归）

    /// 框选完成（selectionDidComplete）时，选区必须吸附到所在屏的物理像素网格，
    /// 并同步回 SelectionView，消除裁剪亚像素取整造成的画面偏移与轻微模糊。
    func test_selectionDidComplete_alignsSelectionToPixelGrid() {
        let controller = CaptureOverlayController(editorEnabled: true)
        controller.pixelScaleForTesting = 2

        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        // 浮点选区（模拟高 DPI 鼠标产生的 0.25 步进坐标）。
        view.updateSelectionRect(NSRect(x: 100.25, y: 200.25, width: 300.3, height: 250.7))
        controller.registerSelectionViewsForTesting([view])

        // 无真实 panel.screen 时后续 guard 会失败 tearDown，但像素对齐发生在 guard 之前。
        controller.selectionDidComplete(
            rect: NSRect(x: 100.25, y: 200.25, width: 300.3, height: 250.7)
        )

        // 2x 屏：吸附到 0.5 点（= 1 物理像素）网格。
        let aligned = view.currentSelectionRect
        XCTAssertEqual(aligned?.origin.x ?? 0, 100.5, accuracy: 0.001, "选区 x 必须吸附到物理像素网格")
        XCTAssertEqual(aligned?.origin.y ?? 0, 200.5, accuracy: 0.001, "选区 y 必须吸附到物理像素网格")
        XCTAssertEqual(aligned?.width ?? 0, 300.5, accuracy: 0.001, "选区宽必须吸附到物理像素网格")
        XCTAssertEqual(aligned?.height ?? 0, 250.5, accuracy: 0.001, "选区高必须吸附到物理像素网格")

        controller.tearDown()
    }

    /// 编辑器态移动/缩放选区结束（二次 complete）时同样要吸附，
    /// 且编辑器布局使用吸附后的矩形。
    func test_selectionDidComplete_editorModeAlignsRectBeforeUpdateLayout() {
        let controller = CaptureOverlayController(editorEnabled: true)
        controller.pixelScaleForTesting = 2

        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        // 模拟框选完成后的选区（编辑器嵌入时选区必须已存在）。
        view.updateSelectionRect(NSRect(x: 50, y: 50, width: 200, height: 150))
        controller.registerSelectionViewsForTesting([view])

        let image = NSImage(size: NSSize(width: 100, height: 80))
        _ = controller.embedEditorForTesting(
            image: image,
            selectionRect: NSRect(x: 50, y: 50, width: 200, height: 150),
            selectionView: view,
            captureRect: CGRect(x: 50, y: 600, width: 200, height: 150)
        )

        controller.selectionDidComplete(
            rect: NSRect(x: 100.25, y: 200.25, width: 300.3, height: 250.7)
        )

        XCTAssertEqual(
            view.currentSelectionRect?.origin.x ?? 0, 100.5, accuracy: 0.001,
            "编辑器态完成选区也必须吸附到像素网格"
        )
        XCTAssertEqual(
            view.currentSelectionRect?.width ?? 0, 300.5, accuracy: 0.001,
            "编辑器态完成选区也必须吸附到像素网格"
        )

        controller.tearDown()
    }

    // MARK: - Helpers

    private func makeMouseEvent(_ type: NSEvent.EventType, at location: NSPoint, eventNumber: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: eventNumber,
            clickCount: 1,
            pressure: 1
        )!
    }
}

/// 副屏误触发选区完成时立即失败，捕捉回归。
private final class FailingSelectionDelegate: SelectionViewDelegate {
    func selectionDidComplete(rect: NSRect) {
        XCTFail("副屏在编辑器嵌入后不得触发 selectionDidComplete")
    }
    func selectionDidCancel() {}
    func selectionDidChange(rect: NSRect) {}
}
