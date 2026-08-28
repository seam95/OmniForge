import AppKit
import XCTest
@testable import OmniForge

@MainActor
final class SelectionInteractionTests: XCTestCase {
    func test_moveByExternalDrag_clampsInsideBounds() {
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let original = NSRect(x: 40, y: 40, width: 100, height: 80)
        view.updateSelectionRect(original)
        view.moveByExternalDrag(deltaFromOriginal: CGSize(width: 1000, height: 1000), originalRect: original)
        let rect = view.currentSelectionRect!
        XCTAssertEqual(rect.maxX, 400, accuracy: 0.5)
        XCTAssertEqual(rect.maxY, 300, accuracy: 0.5)
        XCTAssertEqual(rect.width, 100, accuracy: 0.5)
        XCTAssertEqual(rect.height, 80, accuracy: 0.5)
    }

    /// 拖动中的选区必须吸附物理像素网格（@2x = 0.5pt 网格）：编辑器底图每帧按
    /// captureRect 从快照现裁（`CGImage.cropping(to:)` 对浮点 rect 积分化），
    /// 浮点选区会让裁剪源整数步进与浮点绘制目标产生相位锯齿——挖洞内内容
    /// 在 ±1 物理像素内往返（回归：移动选区时画面轻微抖动）。
    private func assertPixelAligned(_ rect: NSRect, scale: CGFloat, _ label: String) {
        XCTAssertEqual(rect.minX * scale, (rect.minX * scale).rounded(), accuracy: 0.001, "\(label) minX")
        XCTAssertEqual(rect.minY * scale, (rect.minY * scale).rounded(), accuracy: 0.001, "\(label) minY")
        XCTAssertEqual(rect.width * scale, (rect.width * scale).rounded(), accuracy: 0.001, "\(label) width")
        XCTAssertEqual(rect.height * scale, (rect.height * scale).rounded(), accuracy: 0.001, "\(label) height")
    }

    func test_moveDrag_pixelAlignsSelectionToBackingGrid() {
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.backingScaleProvider = { 2 }
        let original = NSRect(x: 40, y: 40, width: 100, height: 80)
        view.updateSelectionRect(original)
        view.selectionLocked = true
        view.annotationToolActive = false

        let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 80, y: 80),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        )!
        view.mouseDown(with: down)
        let drag = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: 110.37, y: 110.62),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 1
        )!
        view.mouseDragged(with: drag)

        let rect = view.currentSelectionRect!
        assertPixelAligned(rect, scale: 2, "move drag")
        XCTAssertEqual(rect.minX, 70.5, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 70.5, accuracy: 0.001)
        XCTAssertEqual(rect.size, original.size)
    }

    func test_resizeByExternalDrag_pixelAlignsSelectionToBackingGrid() {
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.backingScaleProvider = { 2 }
        let original = NSRect(x: 40, y: 40, width: 100, height: 80)
        view.updateSelectionRect(original)

        // topRight：右边跟随 170.3 → 宽 130.3；顶边跟随 100.7 → 高 60.7；均对齐到 0.5
        view.resizeByExternalDrag(
            handle: .topRight, originalRect: original, currentPoint: NSPoint(x: 170.3, y: 100.7)
        )
        let rect = view.currentSelectionRect!
        assertPixelAligned(rect, scale: 2, "external resize")
        XCTAssertEqual(rect.minX, 40, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 40, accuracy: 0.001)
        XCTAssertEqual(rect.width, 130.5, accuracy: 0.001)
        XCTAssertEqual(rect.height, 60.5, accuracy: 0.001)
    }

    func test_moveByExternalDrag_pixelAlignsSelectionToBackingGrid() {
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.backingScaleProvider = { 2 }
        let original = NSRect(x: 40, y: 40, width: 100, height: 80)
        view.updateSelectionRect(original)

        view.moveByExternalDrag(deltaFromOriginal: CGSize(width: 10.33, height: 10.67), originalRect: original)
        let rect = view.currentSelectionRect!
        assertPixelAligned(rect, scale: 2, "external move")
        XCTAssertEqual(rect.minX, 50.5, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 50.5, accuracy: 0.001)
        XCTAssertEqual(rect.size, original.size)
    }

    func test_resizeByExternalDrag_bottomRight_grows() {
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let original = NSRect(x: 50, y: 50, width: 80, height: 60)
        view.updateSelectionRect(original)
        // AppKit 非 flipped：bottomRight 手柄在 (maxX, minY)，向右下拖增大（y 更小为向下）。
        // 拖到 (200, 20)：右边/底边跟随，左边/顶边固定，宽高同时增大。
        view.resizeByExternalDrag(handle: .bottomRight, originalRect: original, currentPoint: NSPoint(x: 200, y: 20))
        let rect = view.currentSelectionRect!
        XCTAssertGreaterThan(rect.width, 80)
        XCTAssertGreaterThan(rect.height, 60)
        // 对面边固定：左边与顶边不得移动
        XCTAssertEqual(rect.minX, original.minX, accuracy: 0.5)
        XCTAssertEqual(rect.maxY, original.maxY, accuracy: 0.5)
    }

    func test_selectionLocked_outsideClickDoesNotResetSelection() {
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let original = NSRect(x: 40, y: 40, width: 100, height: 80)
        view.updateSelectionRect(original)
        view.selectionLocked = true
        view.selectionInteractionEnabled = true
        view.annotationToolActive = false

        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 300, y: 200),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
        view.mouseDown(with: event)

        XCTAssertEqual(view.currentSelectionRect, original)
    }

    /// 非编辑器态（框选阶段）+ 标注工具激活时，选区内点击让给画布，不启动 move。
    func test_annotationToolActive_insideClickDoesNotStartMove_whenUnlocked() {
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let original = NSRect(x: 40, y: 40, width: 100, height: 80)
        view.updateSelectionRect(original)
        view.selectionLocked = false
        view.selectionInteractionEnabled = true
        view.annotationToolActive = true

        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 80, y: 80),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
        view.mouseDown(with: down)

        let drag = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 120, y: 120),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        )!
        view.mouseDragged(with: drag)

        XCTAssertEqual(view.currentSelectionRect, original)
    }

    /// 编辑器态（selectionLocked）时，无论 annotationToolActive 是否为 true，
    /// 选区内按住拖动必须移动选区——这是「进编辑器后按住即拖」的核心。
    func test_insideClickStartsMove_whenEditorLocked_evenWithAnnotationToolActive() {
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let original = NSRect(x: 40, y: 40, width: 100, height: 80)
        view.updateSelectionRect(original)
        view.selectionLocked = true
        view.selectionInteractionEnabled = true
        // 编辑器态 annotationToolActive 恒为 true，但选区拖动不应被它拦截。
        view.annotationToolActive = true

        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 80, y: 80),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
        view.mouseDown(with: down)

        let drag = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 110, y: 110),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        )!
        view.mouseDragged(with: drag)

        let moved = view.currentSelectionRect!
        XCTAssertEqual(moved.origin.x, original.origin.x + 30, accuracy: 0.5)
        XCTAssertEqual(moved.origin.y, original.origin.y + 30, accuracy: 0.5)
        XCTAssertEqual(moved.size, original.size)
    }

    /// 无标注工具（annotationToolActive=false）时，选区内 mouseDown+drag 必须启动
    /// `.move` 并平移选区——这是 CapCap「按住选区直接拖」的入口。
    func test_insideClickStartsMove_whenAnnotationToolInactive() {
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let original = NSRect(x: 40, y: 40, width: 100, height: 80)
        view.updateSelectionRect(original)
        view.selectionLocked = true
        view.selectionInteractionEnabled = true
        view.annotationToolActive = false

        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 80, y: 80),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
        view.mouseDown(with: down)

        let drag = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 110, y: 110),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        )!
        view.mouseDragged(with: drag)

        let moved = view.currentSelectionRect!
        XCTAssertEqual(moved.origin.x, original.origin.x + 30, accuracy: 0.5)
        XCTAssertEqual(moved.origin.y, original.origin.y + 30, accuracy: 0.5)
        XCTAssertEqual(moved.size, original.size)
    }

    /// resolveBaseImageForEditing 在无 preSnapshot 时必须回退到注入的 baseImage，
    /// 保证 preSnapshot 缺失路径仍能渲染底图。
    func test_resolveBaseImageForEditing_fallsBackToBaseImageWhenNoSnapshot() {
        let canvas = AnnotationCanvasView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        let base = NSImage(size: NSSize(width: 100, height: 80))
        canvas.baseImage = base
        canvas.preSnapshot = nil
        canvas.captureRect = nil
        XCTAssertTrue(canvas.resolveBaseImageForEditing() === base)
    }

    /// resolveBaseImageForEditing 在有 previewImage 时优先返回 preview（长截图结果），
    /// 不走现裁/fallback。
    func test_resolveBaseImageForEditing_prefersPreviewImage() {
        let canvas = AnnotationCanvasView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        let base = NSImage(size: NSSize(width: 100, height: 80))
        let preview = NSImage(size: NSSize(width: 100, height: 200))
        canvas.baseImage = base
        canvas.loadPreviewImage(preview)
        XCTAssertTrue(canvas.resolveBaseImageForEditing() === preview)
    }

    func test_finalizeExternalDrag_notifiesComplete() {
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let delegate = RecordingSelectionDelegate()
        view.delegate = delegate
        let original = NSRect(x: 40, y: 40, width: 100, height: 80)
        view.updateSelectionRect(original)
        view.moveByExternalDrag(deltaFromOriginal: CGSize(width: 10, height: 5), originalRect: original)
        // 拖动中仅 change，complete 仅 finalize
        XCTAssertEqual(delegate.completedRects.count, 0)
        XCTAssertFalse(delegate.changedRects.isEmpty)
        view.finalizeExternalDrag()
        XCTAssertEqual(delegate.completedRects.count, 1)
        XCTAssertEqual(delegate.completedRects[0].origin.x, 50, accuracy: 0.5)
        XCTAssertEqual(delegate.completedRects[0].origin.y, 45, accuracy: 0.5)
    }

    func test_chromeOverlay_hitTest_onlyOnHandles() {
        let host = SelectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let overlay = SelectionChromeOverlay(frame: host.bounds)
        overlay.selectionView = host
        host.addSubview(overlay)
        let rect = NSRect(x: 100, y: 100, width: 120, height: 80)
        overlay.update(rect: rect, active: true)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        XCTAssertNil(overlay.hitTest(center))
        let corner = NSPoint(x: rect.minX, y: rect.maxY)
        XCTAssertTrue(overlay.hitTest(corner) === overlay)
    }

    func test_editorShow_defaultsToNoTool() {
        let image = NSImage(size: NSSize(width: 100, height: 80))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 100, height: 80).fill()
        image.unlockFocus()
        let host = SelectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let editor = AnnotationEditorController(
            baseImage: image,
            document: AnnotationDocument(),
            onComplete: { _ in }
        )
        editor.show(in: host, selectionRect: NSRect(x: 20, y: 20, width: 100, height: 80))
        XCTAssertEqual(editor.activeTool, .none)
        editor.tearDown()
    }

    func test_updateLayout_updatesCaptureRectWithoutReplacingBaseImage() {
        let image = NSImage(size: NSSize(width: 100, height: 80))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 100, height: 80).fill()
        image.unlockFocus()

        let document = AnnotationDocument()
        let host = SelectionView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let editor = AnnotationEditorController(
            baseImage: image,
            document: document,
            onComplete: { _ in XCTFail("updateLayout must not invoke onComplete") }
        )
        let initialRect = NSRect(x: 20, y: 20, width: 100, height: 80)
        editor.show(in: host, selectionRect: initialRect)
        let initialBase = editor.canvasView?.baseImage

        let newRect = NSRect(x: 40, y: 50, width: 160, height: 120)

        editor.updateLayout(
            selectionViewRect: newRect,
            captureRect: CGRect(x: 100, y: 200, width: 160, height: 120)
        )

        XCTAssertEqual(editor.selectionViewRectForTesting, newRect)
        // captureRect 必须被更新（draw 时现裁依赖它）。
        XCTAssertEqual(editor.captureRect, CGRect(x: 100, y: 200, width: 160, height: 120))
        // canvas 尺寸跟随选区尺寸。
        let canvasSize = editor.canvasView?.frame.size ?? .zero
        XCTAssertEqual(canvasSize.width, 160, accuracy: 0.5)
        XCTAssertEqual(canvasSize.height, 120, accuracy: 0.5)
        // 底图数据不得被 updateLayout 替换（应由 draw 时按 captureRect 从 preSnapshot 现裁）。
        XCTAssertTrue(
            editor.canvasView?.baseImage === initialBase,
            "updateLayout 不得替换 baseImage；应保持 show 时注入的初始值"
        )
        // 选区变更不得清空已有标注（本用例无标注，确认 document 引用仍存活即可）。
        XCTAssertTrue(document.annotations.isEmpty)

        editor.tearDown()
    }

    /// 移动选区手柄：mouseDown/Dragged/Up 必须驱动 start/delta/end 回调。
    func test_moveSelectionDragHandle_reportsDragLifecycle() {
        let handle = MoveSelectionDragHandle(
            frame: NSRect(x: 0, y: 0, width: 32, height: 32),
            symbolName: "arrow.up.and.down.and.arrow.left.and.right"
        )
        var started = false
        var ended = false
        var lastDelta = CGSize.zero
        handle.onDragStart = { started = true }
        handle.onDrag = { lastDelta = $0 }
        handle.onDragEnd = { ended = true }

        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 16, y: 16),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
        handle.mouseDown(with: down)
        XCTAssertTrue(started)

        let dragged = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 26, y: 21),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        )!
        handle.mouseDragged(with: dragged)
        XCTAssertEqual(lastDelta.width, 10, accuracy: 0.5)
        XCTAssertEqual(lastDelta.height, 5, accuracy: 0.5)

        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 26, y: 21),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 1
        )!
        handle.mouseUp(with: up)
        XCTAssertTrue(ended)
    }

    /// 滚动捕获开启时，选区内中心像素不得仍是冻结快照色（应对齐 dig-out 透出）。
    func test_scrollCaptureActive_skipsBackgroundSnapshotInSelection() {
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 200, height: 160))
        // 纯红冻结快照：若 draw 时仍铺底，选区中心会采样到红。
        let red = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 200,
            pixelsHigh: 160,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: red)
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 160).fill()
        NSGraphicsContext.restoreGraphicsState()
        view.backgroundSnapshot = red.cgImage

        let selection = NSRect(x: 40, y: 30, width: 80, height: 60)
        view.updateSelectionRect(selection)
        view.selectionLocked = true
        view.selectionInteractionEnabled = false
        view.scrollCaptureActive = true
        view.display()

        let image = bitmapSnapshot(of: view)
        // 选区中心：滚动捕获时不应再铺红底，应为透明/清底后的非红像素。
        let center = samplePixel(image, at: NSPoint(x: selection.midX, y: selection.midY))
        XCTAssertFalse(
            isApproximatelyRed(center),
            "scrollCaptureActive 时选区中心仍是冻结红底，说明未跳过 backgroundSnapshot"
        )

        // 选区外仍应有暗化遮罩（非全透明）。
        let outside = samplePixel(image, at: NSPoint(x: 10, y: 10))
        XCTAssertLessThan(outside.alpha, 0.99)
        XCTAssertGreaterThan(outside.alpha, 0.05)
    }

    /// 非滚动态仍绘制冻结快照，避免回归。
    func test_scrollCaptureInactive_drawsBackgroundSnapshot() {
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 200, height: 160))
        let red = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 200,
            pixelsHigh: 160,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: red)
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 160).fill()
        NSGraphicsContext.restoreGraphicsState()
        view.backgroundSnapshot = red.cgImage

        let selection = NSRect(x: 40, y: 30, width: 80, height: 60)
        view.updateSelectionRect(selection)
        view.selectionLocked = true
        view.selectionInteractionEnabled = false
        view.scrollCaptureActive = false
        view.display()

        let image = bitmapSnapshot(of: view)
        let center = samplePixel(image, at: NSPoint(x: selection.midX, y: selection.midY))
        XCTAssertTrue(isApproximatelyRed(center), "非滚动态选区中心应保留冻结红底")
    }

    // MARK: - Bitmap helpers

    private struct RGBA {
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        let alpha: CGFloat
    }

    private func bitmapSnapshot(of view: NSView) -> NSBitmapImageRep {
        let bounds = view.bounds
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width),
            pixelsHigh: Int(bounds.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.draw(bounds)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func samplePixel(_ rep: NSBitmapImageRep, at point: NSPoint) -> RGBA {
        let x = max(0, min(rep.pixelsWide - 1, Int(point.x.rounded())))
        // AppKit 非 flipped：bitmap y=0 在顶部；view y=0 在底部。
        let yFromBottom = max(0, min(rep.pixelsHigh - 1, Int(point.y.rounded())))
        let y = rep.pixelsHigh - 1 - yFromBottom
        guard let color = rep.colorAt(x: x, y: y) else {
            return RGBA(r: 0, g: 0, b: 0, alpha: 0)
        }
        guard let rgb = color.usingColorSpace(.deviceRGB) else {
            return RGBA(r: 0, g: 0, b: 0, alpha: color.alphaComponent)
        }
        return RGBA(
            r: rgb.redComponent,
            g: rgb.greenComponent,
            b: rgb.blueComponent,
            alpha: rgb.alphaComponent
        )
    }

    private func isApproximatelyRed(_ pixel: RGBA) -> Bool {
        pixel.r > 0.8 && pixel.g < 0.2 && pixel.b < 0.2 && pixel.alpha > 0.5
    }
}
