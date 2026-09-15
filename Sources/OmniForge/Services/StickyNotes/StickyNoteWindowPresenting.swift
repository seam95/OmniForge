import Foundation

/// 便签窗口呈现边界：隔离 AppKit 窗口层，使 Manager 的状态机可单测。
/// `show` 为全量同步：确保该便签窗口存在且内容 / 颜色 / 置顶 / frame 与 note 一致
/// （frame 与窗口当前值相同时不动窗口，天然幂等，避免与拖动回写成环）。
@MainActor
protocol StickyNoteWindowPresenting: AnyObject {
    func show(note: StickyNote)
    /// 新建路径专用：显示并聚焦正文，新建后可直接输入。
    /// 仅新建调用；启动恢复等普通 show 路径不得抢焦点。
    func showAndFocus(note: StickyNote)
    func hide(id: UUID)
    /// 关闭并释放窗口（仅删除便签时使用）。
    func dismiss(id: UUID)
    /// 全部隐藏（含置顶便签）。
    func hideAll()
    /// 关闭并释放全部窗口（功能卸载 / 退出）。
    func dismissAll()
    func bringToFront(id: UUID)
}

extension StickyNoteWindowPresenting {
    /// 默认退化为普通 show：无需聚焦的实现（测试 fake 等）零波及。
    /// 须为协议要求而非纯扩展方法——否则调用按声明类型静态分派，
    /// 具体类型的聚焦覆盖不会被调用。
    func showAndFocus(note: StickyNote) {
        show(note: note)
    }
}
