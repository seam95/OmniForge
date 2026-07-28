import CoreGraphics
import Foundation

/// 单次捕获绑定的目标显示器快照（决策 8.1-1：单一目标屏）。
struct CaptureTargetScreen: Equatable, Sendable {
    let displayID: UInt32
    /// AppKit 全局屏幕点坐标下的 frame（左下原点体系）。
    let frameInAppKitPoints: CGRect
    /// 点 → 物理像素比例；UI 侧可用 NSScreen.backingScaleFactor，捕获侧以 filter.pointPixelScale 为准。
    let pointPixelScale: CGFloat

    init(displayID: UInt32, frameInAppKitPoints: CGRect, pointPixelScale: CGFloat) {
        self.displayID = displayID
        self.frameInAppKitPoints = frameInAppKitPoints
        self.pointPixelScale = pointPixelScale
    }
}

/// 一次选区的几何与空间归属（决策 8.1-2：不跨屏；越界部分夹取到目标屏内）。
struct CaptureSelection: Equatable, Sendable {
    let targetScreen: CaptureTargetScreen
    /// AppKit 全局屏幕点矩形（左下原点）；构造时已与目标屏求交并夹取。
    let appKitGlobalRect: CGRect

    /// 输出像素尺寸（由夹取后的点矩形 × pointPixelScale，供 HUD / 固定尺寸校验）。
    var pixelSize: CGSize {
        DisplayCoordinate.pointSizeToPixelSize(
            appKitGlobalRect.size,
            pointPixelScale: targetScreen.pointPixelScale
        )
    }

    /// 目标屏局部、左上原点屏幕点矩形（ScreenCaptureKit 捕获坐标）。
    var captureLocalRect: CGRect {
        DisplayCoordinate.appKitGlobalRectToCaptureLocal(
            appKitGlobalRect,
            screenFrameAppKit: targetScreen.frameInAppKitPoints
        )
    }

    /// 创建选区：矩形须与目标屏有交集；完全在屏外明确失败。
    /// 部分越界时存**夹取后**的交集矩形（决策 8.1-2），保证 `pixelSize` / HUD 与实际捕获一致。
    /// 注意：`CGRect.width/height` 对负尺寸返回绝对值，须用 `size` 校验符号。
    init(targetScreen: CaptureTargetScreen, appKitGlobalRect: CGRect) throws {
        guard appKitGlobalRect.size.width > 0, appKitGlobalRect.size.height > 0 else {
            throw CaptureSelectionError.nonPositiveRect
        }
        let intersection = appKitGlobalRect.intersection(targetScreen.frameInAppKitPoints)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            throw CaptureSelectionError.outsideTargetScreen
        }
        self.targetScreen = targetScreen
        self.appKitGlobalRect = intersection
    }

    /// 将选区再次夹取到目标屏 bounds 内；不改变 targetScreen。
    /// 空交集明确抛错，不 `try!`、不静默退回整屏。
    func clampedToTargetScreen() throws -> CaptureSelection {
        let frame = targetScreen.frameInAppKitPoints
        let clamped = appKitGlobalRect.intersection(frame)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else {
            throw CaptureSelectionError.outsideTargetScreen
        }
        if clamped == appKitGlobalRect {
            return self
        }
        return try CaptureSelection(targetScreen: targetScreen, appKitGlobalRect: clamped)
    }
}

enum CaptureSelectionError: Error, Equatable {
    case nonPositiveRect
    case outsideTargetScreen
}
