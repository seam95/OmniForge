import Foundation

/// 便签几何纯函数：尺寸常量、鼠标落点位置、唤起位置。
/// 全部接收屏幕矩形参数而非直接读 NSScreen，保证可单测。
/// 坐标系为 AppKit 全局坐标（原点在左下，y 向上为正）。
enum StickyNoteGeometry {
    /// 默认尺寸（SPEC D12）。
    static let defaultSize = CGSize(width: 320, height: 260)
    /// 最小尺寸（SPEC D12）。
    static let minimumSize = CGSize(width: 240, height: 180)
    /// 唤起 / 默认位置与屏幕边缘的安全边距。
    static let screenEdgeMargin: CGFloat = 16
    /// 折叠条高度：工具栏 26 + 上下内边距 10。
    static let collapsedHeight: CGFloat = 36

    /// 展开态 frame → 折叠条 frame：顶边对齐原地收缩（工具栏在顶部，视觉位置不动）。
    static func collapsedFrame(expanded: CGRect) -> CGRect {
        CGRect(
            x: expanded.minX,
            y: expanded.maxY - collapsedHeight,
            width: expanded.width,
            height: collapsedHeight
        )
    }

    /// 折叠条 frame → 展开态 frame：顶边对齐反向换算，尺寸取展开态真源
    /// （折叠条的拖动位移只需落到展开 frame 的 origin 上）。
    static func expandedFrame(fromCollapsed frame: CGRect, expandedSize: CGSize) -> CGRect {
        CGRect(
            x: frame.minX,
            y: frame.maxY - expandedSize.height,
            width: expandedSize.width,
            height: expandedSize.height
        )
    }

    /// 新便签位置：以鼠标指针为中心放置，整体钳进指针所在屏的可视区；
    /// 无指针坐标或指针不在任何屏可视区内时，回落主屏默认位置。
    /// `visibleScreens` 首个元素视为主屏。
    static func frameAtMouse(
        _ mouseLocation: CGPoint?,
        size: CGSize,
        visibleScreens: [CGRect]
    ) -> CGRect {
        guard let mouseLocation,
              let screen = visibleScreens.first(where: { $0.contains(mouseLocation) }) else {
            return defaultFrame(size: size, on: visibleScreens)
        }
        let fitted = clampedSizeToFit(size, in: screen)
        let centered = CGRect(
            x: mouseLocation.x - fitted.width / 2,
            y: mouseLocation.y - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
        return WindowFrameVisibility.clampedFrame(centered, toVisibleFrame: screen)
    }

    /// 主屏默认位置：可视区左上角，留安全边距。
    static func defaultFrame(size: CGSize = defaultSize, on visibleScreens: [CGRect]) -> CGRect {
        guard let screen = visibleScreens.first else {
            return CGRect(origin: .zero, size: clampedSize(size))
        }
        let fitted = clampedSizeToFit(size, in: screen)
        return CGRect(
            x: screen.minX + screenEdgeMargin,
            y: screen.maxY - fitted.height - screenEdgeMargin,
            width: fitted.width,
            height: fitted.height
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
