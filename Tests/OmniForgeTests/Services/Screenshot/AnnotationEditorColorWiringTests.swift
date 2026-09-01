import AppKit
import XCTest
@testable import OmniForge

/// 控制器级颜色接线回归：画笔/直线/箭头/矩形/椭圆子工具栏的色板点击
/// 必须经 `setCurrentDrawingColor` 推到画布，否则标注永远停留在默认红色。
@MainActor
final class AnnotationEditorColorWiringTests: XCTestCase {

    private let hostSize = NSSize(width: 200, height: 150)

    private func makeEditor() -> (SelectionView, AnnotationEditorController) {
        let host = SelectionView(frame: NSRect(origin: .zero, size: hostSize))
        let editor = AnnotationEditorController(
            baseImage: NSImage(size: hostSize),
            document: AnnotationDocument(),
            resultRunner: FakeScreenshotResultRunner(),
            makeResult: { _ in nil },
            onComplete: { _ in }
        )
        editor.show(in: host, selectionRect: NSRect(origin: .zero, size: hostSize))
        return (host, editor)
    }

    /// 递归查找宿主视图树中的子工具栏。
    private func findColorSizeSubToolbar(in view: NSView) -> ColorSizeSubToolbar? {
        if let sub = view as? ColorSizeSubToolbar { return sub }
        for child in view.subviews {
            if let found = findColorSizeSubToolbar(in: child) { return found }
        }
        return nil
    }

    /// 以与真实点击相同的 target/action 派发路径触发色板点击。
    private func fireColorTap(on swatch: NSView) {
        guard let recognizer = swatch.gestureRecognizers.first,
              let target = recognizer.target,
              let action = recognizer.action else {
            return XCTFail("色板缺少点击手势")
        }
        _ = target.perform(action, with: recognizer)
    }

    private func colorsClose(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let ac = a.usingColorSpace(.deviceRGB),
              let bc = b.usingColorSpace(.deviceRGB) else { return false }
        return abs(ac.redComponent - bc.redComponent) < 0.01 &&
            abs(ac.greenComponent - bc.greenComponent) < 0.01 &&
            abs(ac.blueComponent - bc.blueComponent) < 0.01
    }

    func test_colorTap_pushesColorToCanvas_forDrawingTools() throws {
        let blue = EditorStyleDefaults.paletteColors[1]
        // 荧光笔走独立色槽，不在本组。
        let tools: [EditTool] = [.pen, .line, .arrow, .rectangle, .ellipse]

        for tool in tools {
            let (host, editor) = makeEditor()
            defer { editor.close() }

            editor.selectTool(tool)
            let sub = try XCTUnwrap(findColorSizeSubToolbar(in: host), "\(tool) 应安装 ColorSizeSubToolbar")
            let swatches = sub.subviews.compactMap { $0 as? ColorSwatchView }
            XCTAssertGreaterThanOrEqual(swatches.count, 2, "\(tool) 子工具栏应有色板")

            fireColorTap(on: swatches[1]) // 蓝色

            let canvasColor = try XCTUnwrap(editor.canvasView?.currentColor, "\(tool) 画布应有当前颜色")
            XCTAssertTrue(colorsClose(canvasColor, blue),
                          "\(tool) 色板点蓝后画布颜色应更新为蓝，实际 \(canvasColor)")
        }
    }

    func test_colorTap_updatesMarkerSlot_forMarkerTool() throws {
        let blue = EditorStyleDefaults.paletteColors[1]
        let (host, editor) = makeEditor()
        defer { editor.close() }

        editor.selectTool(.marker)
        let sub = try XCTUnwrap(findColorSizeSubToolbar(in: host))
        let swatches = sub.subviews.compactMap { $0 as? ColorSwatchView }

        fireColorTap(on: swatches[1])

        let markerColor = try XCTUnwrap(editor.canvasView?.currentMarkerColor)
        XCTAssertTrue(colorsClose(markerColor, blue), "荧光笔色板点击应更新独立色槽")
    }
}
