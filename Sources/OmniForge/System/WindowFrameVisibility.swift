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

    /// 「面板必须完整可见」口径的归一化：与某屏可见区相交时把 origin 夹进相交面积
    /// 最大的屏（保持尺寸），完全不相交时才回落居中。
    ///
    /// 与 `normalizedFrame` 的「≥50×50 即放行」不同——系统升级或屏幕重排后，持久化
    /// 位置可能半悬屏外（底部伸出屏幕），旧口径会原样放行。
    static func clampedFrame(
        _ frame: NSRect,
        visibleScreens: [NSRect],
        centerFallback: () -> NSRect
    ) -> NSRect {
        var best: (screen: NSRect, area: CGFloat)?
        for screen in visibleScreens {
            let intersection = frame.intersection(screen)
            guard !intersection.isNull, !intersection.isInfinite else { continue }
            let area = intersection.width * intersection.height
            if area > (best?.area ?? 0) {
                best = (screen, area)
            }
        }
        guard let target = best?.screen else { return centerFallback() }
        return clampedFrame(frame, toVisibleFrame: target)
    }

    /// 把 origin 夹入指定可见区，保持尺寸；窗口比可见区大时对齐 minX/minY。
    static func clampedFrame(_ frame: NSRect, toVisibleFrame visible: NSRect) -> NSRect {
        var origin = frame.origin
        if frame.width <= visible.width {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - frame.width)
        } else {
            origin.x = visible.minX
        }
        if frame.height <= visible.height {
            origin.y = min(max(origin.y, visible.minY), visible.maxY - frame.height)
        } else {
            origin.y = visible.minY
        }
        return NSRect(origin: origin, size: frame.size)
    }

    /// 使用当前 `NSScreen.screens` 的 visibleFrame 做夹回归一化。
    static func clampedFrameOnCurrentScreens(
        _ frame: NSRect,
        centerFallback: () -> NSRect
    ) -> NSRect {
        clampedFrame(
            frame,
            visibleScreens: NSScreen.screens.map(\.visibleFrame),
            centerFallback: centerFallback
        )
    }
}
