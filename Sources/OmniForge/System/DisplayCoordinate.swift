import CoreGraphics
import Foundation

/// 截图三空间坐标纯函数转换器（SPEC 4.1）。
///
/// | 空间 | 单位 | 原点/轴向 |
/// | AppKit 全局 | 屏幕点 | AppKit（全局左下） |
/// | 捕获局部 | 目标屏屏幕点 | 左上原点 |
/// | 图片/标注 | 物理像素 | 左上原点 |
///
/// 所有进入 Core Graphics / 捕获 API 的矩形在此集中转换并明确取整。
/// 单屏模型：转换以指定 targetScreen / screenFrame 为参数，不做全桌面合成。
enum DisplayCoordinate {
    // MARK: - CG 全局（左上原点，主屏高度为基准）↔ AppKit 全局（左下原点）

    /// AppKit 全局点（左下原点）→ CG 全局点（左上原点，主屏高度为基准）。
    static func appKitGlobalPointToCGGlobal(
        _ point: CGPoint,
        primaryDisplayHeight: CGFloat
    ) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
    }

    /// CG 全局点（左上原点，主屏高度为基准）→ AppKit 全局点（左下原点）。
    static func cgGlobalPointToAppKitGlobal(
        _ point: CGPoint,
        primaryDisplayHeight: CGFloat
    ) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
    }

    /// `SCWindow.frame` / `kCGWindowBounds` 使用 CG 全局坐标系（Y 向下，原点在主屏左上）。
    /// 转成 AppKit 全局点，供遮罩命中与 `NSEvent.mouseLocation` 使用。
    static func cgGlobalRectToAppKitGlobal(
        _ rect: CGRect,
        primaryDisplayHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryDisplayHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    static func appKitGlobalRectToCGGlobal(
        _ rect: CGRect,
        primaryDisplayHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryDisplayHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - AppKit 全局点 ↔ 捕获局部点（Y 翻转）

    static func appKitGlobalPointToCaptureLocal(
        _ point: CGPoint,
        screenFrameAppKit: CGRect
    ) -> CGPoint {
        CGPoint(
            x: point.x - screenFrameAppKit.minX,
            y: screenFrameAppKit.maxY - point.y
        )
    }

    static func captureLocalPointToAppKitGlobal(
        _ point: CGPoint,
        screenFrameAppKit: CGRect
    ) -> CGPoint {
        CGPoint(
            x: point.x + screenFrameAppKit.minX,
            y: screenFrameAppKit.maxY - point.y
        )
    }

    static func appKitGlobalRectToCaptureLocal(
        _ rect: CGRect,
        screenFrameAppKit: CGRect
    ) -> CGRect {
        // 顶边：AppKit maxY → 距屏顶 0 方向
        let topLeftLocal = appKitGlobalPointToCaptureLocal(
            CGPoint(x: rect.minX, y: rect.maxY),
            screenFrameAppKit: screenFrameAppKit
        )
        return CGRect(x: topLeftLocal.x, y: topLeftLocal.y, width: rect.width, height: rect.height)
    }

    static func captureLocalRectToAppKitGlobal(
        _ rect: CGRect,
        screenFrameAppKit: CGRect
    ) -> CGRect {
        // capture 顶边 y → AppKit 上边；底边 = 上边 - height
        let topLeftAppKit = captureLocalPointToAppKitGlobal(
            CGPoint(x: rect.minX, y: rect.minY),
            screenFrameAppKit: screenFrameAppKit
        )
        return CGRect(
            x: topLeftAppKit.x,
            y: topLeftAppKit.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - 点 ↔ 物理像素

    static func pointSizeToPixelSize(_ size: CGSize, pointPixelScale: CGFloat) -> CGSize {
        CGSize(width: size.width * pointPixelScale, height: size.height * pointPixelScale)
    }

    static func pixelSizeToPointSize(_ size: CGSize, pointPixelScale: CGFloat) -> CGSize {
        CGSize(width: size.width / pointPixelScale, height: size.height / pointPixelScale)
    }

    static func captureLocalRectToPixelRect(
        _ rect: CGRect,
        pointPixelScale: CGFloat
    ) -> CGRect {
        let scaled = CGRect(
            x: rect.origin.x * pointPixelScale,
            y: rect.origin.y * pointPixelScale,
            width: rect.width * pointPixelScale,
            height: rect.height * pointPixelScale
        )
        return integralizedPixelRect(scaled)
    }

    static func pixelRectToCaptureLocal(
        _ rect: CGRect,
        pointPixelScale: CGFloat
    ) -> CGRect {
        CGRect(
            x: rect.origin.x / pointPixelScale,
            y: rect.origin.y / pointPixelScale,
            width: rect.width / pointPixelScale,
            height: rect.height / pointPixelScale
        )
    }

    /// AppKit 全局矩形 → 目标屏物理像素矩形（左上原点）。
    static func appKitGlobalRectToPixelRect(
        _ rect: CGRect,
        targetScreen: CaptureTargetScreen
    ) -> CGRect {
        let local = appKitGlobalRectToCaptureLocal(
            rect,
            screenFrameAppKit: targetScreen.frameInAppKitPoints
        )
        return captureLocalRectToPixelRect(local, pointPixelScale: targetScreen.pointPixelScale)
    }

    // MARK: - 集中取整

    /// 像素矩形取整：origin 向下、max 向上，避免裁切丢边。
    static func integralizedPixelRect(_ rect: CGRect) -> CGRect {
        let minX = floor(rect.minX)
        let minY = floor(rect.minY)
        let maxX = ceil(rect.maxX)
        let maxY = ceil(rect.maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
