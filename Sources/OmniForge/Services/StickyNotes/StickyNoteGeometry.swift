import Foundation

/// 便签几何纯函数：尺寸常量、级联位置、唤起位置。
/// 全部接收屏幕矩形参数而非直接读 NSScreen，保证可单测。
/// 坐标系为 AppKit 全局坐标（原点在左下，y 向上为正）。
enum StickyNoteGeometry {
    /// 默认尺寸（SPEC D12）。
    static let defaultSize = CGSize(width: 320, height: 260)
    /// 最小尺寸（SPEC D12）。
    static let minimumSize = CGSize(width: 240, height: 180)
    /// 新便签相对最近创建便签的级联偏移：视觉上向右下移动 28pt。
    static let cascadeOffset = CGVector(dx: 28, dy: -28)
    /// 唤起 / 默认位置与屏幕边缘的安全边距。
    static let screenEdgeMargin: CGFloat = 16

    /// 新便签位置：最近创建便签 frame 级联偏移；无历史或越出屏幕可视区
    /// （候选位置未被任何屏完整包含）时回落主屏默认位置。
    /// `visibleScreens` 首个元素视为主屏。
    static func cascadeFrame(
        lastCreatedFrame: CGRect?,
        visibleScreens: [CGRect]
    ) -> CGRect {
        guard let lastCreatedFrame else {
            return defaultFrame(on: visibleScreens)
        }
        let candidate = lastCreatedFrame.offsetBy(dx: cascadeOffset.dx, dy: cascadeOffset.dy)
        if isFullyContained(candidate, in: visibleScreens) {
            return candidate
        }
        return defaultFrame(on: visibleScreens)
    }

    /// 主屏默认位置：可视区左上角，留安全边距（级联链向右下展开）。
    static func defaultFrame(on visibleScreens: [CGRect]) -> CGRect {
        guard let screen = visibleScreens.first else {
            return CGRect(origin: .zero, size: defaultSize)
        }
        let size = clampedSizeToFit(defaultSize, in: screen)
        return CGRect(
            x: screen.minX + screenEdgeMargin,
            y: screen.maxY - size.height - screenEdgeMargin,
            width: size.width,
            height: size.height
        )
    }

    /// 提醒唤起位置：目标屏可视区上方居中（顶部留边距）。
    static func awakenFrame(size: CGSize, on screen: CGRect) -> CGRect {
        let fitted = clampedSizeToFit(size, in: screen)
        return CGRect(
            x: screen.midX - fitted.width / 2,
            y: screen.maxY - fitted.height - screenEdgeMargin,
            width: fitted.width,
            height: fitted.height
        )
    }

    /// 尺寸钳制到最小尺寸。
    static func clampedSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(minimumSize.width, size.width),
            height: max(minimumSize.height, size.height)
        )
    }

    /// 是否被任一屏完整包含（含等值边界）。
    static func isFullyContained(_ frame: CGRect, in visibleScreens: [CGRect]) -> Bool {
        visibleScreens.contains { screen in
            frame.minX >= screen.minX
                && frame.maxX <= screen.maxX
                && frame.minY >= screen.minY
                && frame.maxY <= screen.maxY
        }
    }

    /// 屏幕过小时按比例缩到屏内，仍受最小尺寸约束。
    private static func clampedSizeToFit(_ size: CGSize, in screen: CGRect) -> CGSize {
        let width = min(max(size.width, minimumSize.width), screen.width)
        let height = min(max(size.height, minimumSize.height), screen.height)
        return CGSize(width: width, height: height)
    }
}
