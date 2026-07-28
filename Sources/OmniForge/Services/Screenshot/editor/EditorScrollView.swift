import AppKit

/// 编辑器滚动视图：工具未激活时只转发 canvas 自身 claim 的命中，
/// 空白区域透传给下方 SelectionView / chrome handles。
final class EditorScrollView: NSScrollView {
    weak var editorCanvasView: AnnotationCanvasView?
    /// `true`：viewport 内全部点击由滚动视图捕获（绘制工具 / preview）。
    /// `false`：仅转发 canvas 已 claim 的命中。
    var isInteractionEnabled = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        if isInteractionEnabled { return result }
        guard let canvas = editorCanvasView, let hit = result else { return nil }
        if hit === canvas || hit.isDescendant(of: canvas) { return hit }
        return nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
