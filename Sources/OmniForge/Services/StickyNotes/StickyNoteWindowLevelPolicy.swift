import AppKit

/// 便签窗口层级策略：把「置顶」与「选中态临时抬升」两个维度收口到唯一裁决点。
///
/// 背景：未置顶便签原本只有 `.normal` 层级，前置完全依赖一次性 `orderFrontRegardless`。
/// 系统代用户选中窗口的路径（调度中心 / Exposé）不经过应用内点击逻辑，退场后
/// 窗口服务器重排会把便签压回前台应用窗口之下——表现为「短暂显示约 1 秒又被覆盖」。
/// 窗口成为 key（被选中）期间把层级抬高一档，使系统重排后便签仍保持在前；
/// 窗口失焦即回落普通层级，保留「用户再点其他窗口后仍会被盖住」的既有语义（SPEC 4.5）。
///
/// 抬升取 `.normal + 1` 而非 `.floating`：只压过普通窗口，不越过其他应用的浮动
/// 面板，也不与「置顶」语义混同。
enum StickyNoteWindowLevelPolicy {
    /// 选中态临时层级：高于 `.normal`、低于 `.floating`。
    static let selectionPromotedLevel = NSWindow.Level(
        rawValue: NSWindow.Level.normal.rawValue + 1
    )

    /// 窗口层级：置顶恒为 `.floating`；未置顶时选中态抬升一档。
    static func level(pinned: Bool, selectionPromoted: Bool) -> NSWindow.Level {
        if pinned { return .floating }
        return selectionPromoted ? selectionPromotedLevel : .normal
    }

    /// 集合行为只由置顶决定：选中态不跨 Space（跨 Space 会变成事实置顶）。
    static func collectionBehavior(pinned: Bool) -> NSWindow.CollectionBehavior {
        pinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            : [.fullScreenAuxiliary, .ignoresCycle]
    }
}
