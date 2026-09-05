import CoreGraphics
import Foundation

/// 控制中心尺寸契约输入（SPEC §3.1）。所有高度均为逻辑点。
struct ControlCenterSizingInput: Equatable {
    /// 面板宽度（固定 380pt）。
    var width: CGFloat
    /// 以实际内容宽度布局的页面自然高度（含页面自身 padding，
    /// 不含被分配的 viewport 高度）。
    var naturalContentHeight: CGFloat
    /// 导航、恢复 Banner、footer 的实际总高。
    var chromeHeight: CGFloat
    /// 当前锚点屏幕方向上的可容纳内容总高（含 chrome）。
    var availableTotalHeight: CGFloat
    /// 空状态/不可用页：应用 120pt 下限（SPEC §3.1）。
    var isEmptyState: Bool
    /// 屏幕 backing scale；高度按物理像素对齐。
    var backingScale: CGFloat

    static func == (lhs: ControlCenterSizingInput, rhs: ControlCenterSizingInput) -> Bool {
        lhs.width == rhs.width
            && lhs.naturalContentHeight == rhs.naturalContentHeight
            && lhs.chromeHeight == rhs.chromeHeight
            && lhs.availableTotalHeight == rhs.availableTotalHeight
            && lhs.isEmptyState == rhs.isEmptyState
            && lhs.backingScale == rhs.backingScale
    }
}

/// 解析后的尺寸目标：viewport 驱动 SwiftUI 内容区，total 为提交给
/// popover.contentSize 的高度。
struct ControlCenterSizingTarget: Equatable {
    var viewportHeight: CGFloat
    var totalHeight: CGFloat
}

/// 控制中心自适应高度纯计算（SPEC §3.1 尺寸契约）：
///
/// ```text
/// Hcap      = max(0, min(Hmax, Havailable - Hchrome))
/// Hviewport = min(Hcap, max(Hnatural, HemptyFloor))
/// Htotal    = Hchrome + Hviewport
/// ```
///
/// 纯函数、无 AppKit 依赖：屏幕可用高度、chrome 实测高度由调用方注入，
/// 便于覆盖极小屏幕、空态、非有限测量等边界。
enum ControlCenterSizingPolicy {
    /// 内容 viewport 上限（原固定高度，现作为自适应上限）。
    static var maxViewportHeight: CGFloat { ControlCenterContentMetrics.viewportHeight }
    /// 空状态/不可用页的最小内容高度。
    static var emptyFloorHeight: CGFloat { ControlCenterContentMetrics.emptyContentMinHeight }

    /// 解析尺寸目标。测量无效（非有限或 ≤0）时返回 nil，调用方保持
    /// 当前尺寸或走降级路径，不得以无效值驱动改高。
    static func resolve(_ input: ControlCenterSizingInput) -> ControlCenterSizingTarget? {
        guard input.naturalContentHeight.isFinite, input.naturalContentHeight > 0 else {
            return nil
        }
        guard input.chromeHeight.isFinite, input.chromeHeight >= 0 else { return nil }
        guard input.availableTotalHeight.isFinite, input.availableTotalHeight > 0 else {
            return nil
        }
        guard input.backingScale.isFinite, input.backingScale > 0 else { return nil }

        let cap = max(0, min(maxViewportHeight, input.availableTotalHeight - input.chromeHeight))
        // 极小可用空间下屏幕上限优先：emptyFloor 仅在 cap 允许时生效。
        let floor = input.isEmptyState ? min(emptyFloorHeight, cap) : 0
        let viewport = min(cap, max(input.naturalContentHeight, floor))
        let total = pixelAligned(input.chromeHeight + viewport, scale: input.backingScale)
        // 对齐只降不升：确保 total 仍满足 ≤ available（若可用高度本身非整像素，
        // 允许 1 物理像素内的安全偏差）。
        return ControlCenterSizingTarget(
            viewportHeight: max(0, total - input.chromeHeight),
            totalHeight: max(input.chromeHeight, total)
        )
    }

    /// 按 backing scale 向下对齐物理像素（向下确保不超屏幕上限）。
    static func pixelAligned(_ height: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0, height.isFinite else { return height }
        return (floor(height * scale) / scale)
    }

    /// 两个高度的差异是否在 1 个物理像素内（满足即不重复提交，SPEC §3.1）。
    static func isEffectivelyEqual(_ a: CGFloat, _ b: CGFloat, scale: CGFloat) -> Bool {
        guard a.isFinite, b.isFinite, scale > 0 else { return false }
        return abs(a - b) * scale <= 1
    }
}
