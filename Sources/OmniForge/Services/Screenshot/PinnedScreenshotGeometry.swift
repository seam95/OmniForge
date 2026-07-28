import CoreGraphics
import Foundation

/// 钉图显示几何与约束纯函数（可单测，不依赖真实窗口）。
/// 缩放改变的是显示尺寸，不修改底层像素。
enum PinnedScreenshotGeometry {
    /// 最小显示边长（点），避免缩到不可见。
    static let minDisplayEdgePoints: CGFloat = 48
    /// 最大显示边长（点），避免无界撑爆。
    static let maxDisplayEdgePoints: CGFloat = 2_400
    static let minScale: CGFloat = 0.05
    static let maxScale: CGFloat = 8
    static let defaultScale: CGFloat = 1
    static let minOpacity: CGFloat = 0.15
    static let maxOpacity: CGFloat = 1
    static let defaultOpacity: CGFloat = 1

    /// 缩放锚点：滚轮缩放时固定一种可测策略。
    enum ScaleAnchor: Equatable, Sendable {
        /// 以窗口中心为锚（实现默认）。
        case windowCenter
        /// 以给定窗口局部点为锚（点坐标，相对当前 frame 左下）。
        case localPoint(CGPoint)
    }

    /// 像素尺寸 → 点尺寸（scale=1 时的自然显示尺寸）。
    static func naturalDisplaySize(
        pixelWidth: Int,
        pixelHeight: Int,
        pointPixelScale: CGFloat
    ) -> CGSize? {
        guard pixelWidth > 0, pixelHeight > 0, pointPixelScale > 0 else { return nil }
        return CGSize(
            width: CGFloat(pixelWidth) / pointPixelScale,
            height: CGFloat(pixelHeight) / pointPixelScale
        )
    }

    /// 等比缩放后的显示尺寸；无效输入返回 nil。
    static func displaySize(
        pixelWidth: Int,
        pixelHeight: Int,
        pointPixelScale: CGFloat,
        scale: CGFloat
    ) -> CGSize? {
        guard let natural = naturalDisplaySize(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            pointPixelScale: pointPixelScale
        ) else {
            return nil
        }
        let s = clampedScale(scale)
        return CGSize(width: natural.width * s, height: natural.height * s)
    }

    /// 夹取缩放比例。
    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return defaultScale }
        return min(max(scale, minScale), maxScale)
    }

    /// 夹取透明度。
    static func clampedOpacity(_ opacity: CGFloat) -> CGFloat {
        guard opacity.isFinite else { return defaultOpacity }
        return min(max(opacity, minOpacity), maxOpacity)
    }

    /// 将期望尺寸夹到最小/最大边长，并保持宽高比。
    /// - Returns: 夹取后的尺寸；若宽高比无效则 nil。
    static func clampedDisplaySize(_ size: CGSize) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            return nil
        }
        let aspect = size.width / size.height
        guard aspect.isFinite, aspect > 0 else { return nil }

        var width = size.width
        var height = size.height

        // 先按最大边夹取
        let maxEdge = max(width, height)
        if maxEdge > maxDisplayEdgePoints {
            let factor = maxDisplayEdgePoints / maxEdge
            width *= factor
            height *= factor
        }

        // 再按最小边抬升
        let minEdge = min(width, height)
        if minEdge < minDisplayEdgePoints {
            let factor = minDisplayEdgePoints / minEdge
            width *= factor
            height *= factor
            // 抬升后可能超过最大边，再次压回
            let maxEdge2 = max(width, height)
            if maxEdge2 > maxDisplayEdgePoints {
                let factor2 = maxDisplayEdgePoints / maxEdge2
                width *= factor2
                height *= factor2
            }
        }

        // 数值抖动后按宽高比微调高度
        height = width / aspect
        return CGSize(width: width, height: height)
    }

    /// 将自然显示尺寸缩放到可见区内，保持宽高比。
    /// 参照 capcap `PinLauncher.fittedSize`：**只缩小不放大**（ratio ≤ 1），
    /// 永不把小图强制抬升（这是钉住时"自动放大"的根因）。
    /// - Parameters:
    ///   - naturalSize: 像素尺寸 ÷ pointPixelScale 得到的点尺寸（scale=1 自然显示尺寸）。
    ///   - visibleFrame: 目标屏可见区。
    /// - Returns: 缩放后尺寸；无效输入返回原值（与 capcap 一致，不返回 nil）。
    static func fittedSize(for naturalSize: CGSize, in visibleFrame: CGRect) -> CGSize {
        guard naturalSize.width > 0, naturalSize.height > 0 else { return naturalSize }
        let maxWidth = max(200, visibleFrame.width - 80)
        let maxHeight = max(200, visibleFrame.height - 80)
        let ratio = min(1.0, min(maxWidth / naturalSize.width, maxHeight / naturalSize.height))
        if ratio >= 1.0 { return naturalSize }
        return CGSize(width: floor(naturalSize.width * ratio), height: floor(naturalSize.height * ratio))
    }

    /// 由当前 frame 与目标缩放倍率计算新 frame（保持宽高比，锚点策略固定）。
    /// `scaleFactor` 为相对当前尺寸的乘数（如 1.1 放大 10%）。
    static func scaledFrame(
        currentFrame: CGRect,
        scaleFactor: CGFloat,
        anchor: ScaleAnchor = .windowCenter
    ) -> CGRect? {
        guard currentFrame.width > 0, currentFrame.height > 0,
              scaleFactor.isFinite, scaleFactor > 0 else {
            return nil
        }
        let proposed = CGSize(
            width: currentFrame.width * scaleFactor,
            height: currentFrame.height * scaleFactor
        )
        guard let clamped = clampedDisplaySize(proposed) else { return nil }

        let anchorPoint: CGPoint
        switch anchor {
        case .windowCenter:
            anchorPoint = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
        case .localPoint(let local):
            anchorPoint = CGPoint(
                x: currentFrame.minX + local.x,
                y: currentFrame.minY + local.y
            )
        }

        let relX = (anchorPoint.x - currentFrame.minX) / currentFrame.width
        let relY = (anchorPoint.y - currentFrame.minY) / currentFrame.height
        let newOrigin = CGPoint(
            x: anchorPoint.x - clamped.width * relX,
            y: anchorPoint.y - clamped.height * relY
        )
        return CGRect(origin: newOrigin, size: clamped)
    }

    /// 将窗口完整放入 `visibleFrame`；优先保持 `preferredOrigin`，必要时平移。
    static func frameFittingVisibleArea(
        size: CGSize,
        preferredOrigin: CGPoint?,
        visibleFrame: CGRect
    ) -> CGRect? {
        guard let clampedSize = clampedDisplaySize(size),
              visibleFrame.width > 0, visibleFrame.height > 0 else {
            return nil
        }

        // 若可见区域比最小尺寸还小，仍返回夹取尺寸（调用方负责显示）。
        var origin = preferredOrigin ?? CGPoint(
            x: visibleFrame.midX - clampedSize.width / 2,
            y: visibleFrame.midY - clampedSize.height / 2
        )

        let maxX = visibleFrame.maxX - clampedSize.width
        let maxY = visibleFrame.maxY - clampedSize.height
        if maxX >= visibleFrame.minX {
            origin.x = min(max(origin.x, visibleFrame.minX), maxX)
        } else {
            origin.x = visibleFrame.minX
        }
        if maxY >= visibleFrame.minY {
            origin.y = min(max(origin.y, visibleFrame.minY), maxY)
        } else {
            origin.y = visibleFrame.minY
        }

        return CGRect(origin: origin, size: clampedSize)
    }

    /// 由当前显示尺寸反推相对自然尺寸的 scale。
    static func scale(
        displaySize: CGSize,
        pixelWidth: Int,
        pixelHeight: Int,
        pointPixelScale: CGFloat
    ) -> CGFloat? {
        guard let natural = naturalDisplaySize(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            pointPixelScale: pointPixelScale
        ), natural.width > 0 else {
            return nil
        }
        return clampedScale(displaySize.width / natural.width)
    }
}
