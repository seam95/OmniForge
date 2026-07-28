import AppKit
import Foundation

/// 纯函数工具：判断窗口 frame 是否足够可见；不可见时回落到居中 frame。
enum WindowFrameVisibility {
    static let defaultMinimumVisibleSize = NSSize(width: 50, height: 50)

    /// 若 frame 与任一可见屏相交区域不小于阈值，则保留；否则使用 centerFallback。
    static func normalizedFrame(
        _ frame: NSRect,
        visibleScreens: [NSRect],
        minimumVisibleSize: NSSize = defaultMinimumVisibleSize,
        centerFallback: () -> NSRect
    ) -> NSRect {
        if isSufficientlyVisible(
            frame,
            on: visibleScreens,
            minimumVisibleSize: minimumVisibleSize
        ) {
            return frame
        }
        return centerFallback()
    }

    static func isSufficientlyVisible(
        _ frame: NSRect,
        on visibleScreens: [NSRect],
        minimumVisibleSize: NSSize = defaultMinimumVisibleSize
    ) -> Bool {
        for screen in visibleScreens {
            let intersection = frame.intersection(screen)
            guard !intersection.isNull, !intersection.isInfinite else { continue }
            if intersection.width >= minimumVisibleSize.width,
               intersection.height >= minimumVisibleSize.height {
                return true
            }
        }
        return false
    }

    /// 使用当前 `NSScreen.screens` 的 visibleFrame 做归一化。
    static func normalizedFrameOnCurrentScreens(
        _ frame: NSRect,
        minimumVisibleSize: NSSize = defaultMinimumVisibleSize,
        centerFallback: () -> NSRect
    ) -> NSRect {
        let screens = NSScreen.screens.map(\.visibleFrame)
        return normalizedFrame(
            frame,
            visibleScreens: screens,
            minimumVisibleSize: minimumVisibleSize,
            centerFallback: centerFallback
        )
    }
}
