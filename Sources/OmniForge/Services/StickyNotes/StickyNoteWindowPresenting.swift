import Foundation

/// 便签窗口呈现边界：隔离 AppKit 窗口层，使 Manager 的状态机可单测。
/// `show` 为全量同步：确保该便签窗口存在且内容 / 颜色 / 置顶 / frame 与 note 一致
/// （frame 与窗口当前值相同时不动窗口，天然幂等，避免与拖动回写成环）。
@MainActor
protocol StickyNoteWindowPresenting: AnyObject {
    func show(note: StickyNote)
    func hide(id: UUID)
    /// 关闭并释放窗口（仅删除便签时使用）。
    func dismiss(id: UUID)
    /// 全部隐藏（含置顶便签）。
    func hideAll()
    /// 关闭并释放全部窗口（功能卸载 / 退出）。
    func dismissAll()
    func bringToFront(id: UUID)
}
