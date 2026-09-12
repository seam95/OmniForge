import CoreGraphics
import Foundation

/// alpha 命中：按当前显示快照判定指针是否落在实体像素（或容差邻域）内。
///
/// 命中读取最终显示快照的帧与镜像标记，显式处理 Y 翻转、水平镜像、非正方形
/// 缩放与 Retina（膨胀半径以显示 pt 定义再换算帧像素，不把设备像素当 pt）。
/// 容差采用缓存膨胀 mask（实体像素按半径 dilate），非中心加外围四点近似。
@MainActor
final class PetAlphaHitTester {
    /// alpha 阈值：> 该值视为实体像素。
    static let alphaThreshold: UInt8 = 8
    /// 容差（显示 pt）：高度 ≤72pt 用 8，其余 6。
    static let smallTolerance: CGFloat = 8
    static let defaultTolerance: CGFloat = 6
    /// 小尺寸判定线（显示 pt）。
    static let smallSizeCutoff: CGFloat = 72
    /// 膨胀 mask 缓存上限（项）；超出整体清空重建（有界）。
    static let cacheLimit = 64

    /// 单帧膨胀 mask：帧像素网格 + 命中判定。
    private struct FrameMask {
        let width: Int
        let height: Int
        /// 膨胀后的实体标记（行优先，顶行在前——与 CGImage.cropping 直读口径一致）。
        let dilated: [Bool]
    }

    private var maskCache: [String: FrameMask] = [:]

    /// 指针是否命中实体像素（含容差邻域）。
    /// - Parameters:
    ///   - localPoint: 窗口本地坐标（左下原点，pt；已由调用方从全局坐标换算）。
    ///   - snapshot: 当前最终显示快照（帧、镜像与显示尺寸的唯一真相）。
    ///   - frameImage: 快照帧的 CGImage（与渲染共享同一裁剪口径的位图）。
    /// - Returns: false = 该点应穿透到下层窗口；快照或帧缺失时返回 true（矩形命中兜底，
    ///   避免缺资产 / 裁剪失败时宠物无法操作）。
    func contains(_ localPoint: CGPoint, snapshot: PetDisplaySnapshot, frameImage: CGImage?) -> Bool {
        guard let frameImage else { return true }
        let displaySize = snapshot.size
        // 窗口外一点即未命中（容差限定在窗口矩形内）。
        guard localPoint.x >= 0, localPoint.x <= displaySize.width,
              localPoint.y >= 0, localPoint.y <= displaySize.height else {
            return false
        }
        let tolerance = Self.tolerance(forDisplayHeight: displaySize.height)
        let mask = mask(
            assetID: snapshot.asset.id,
            frameIndex: snapshot.frameIndex,
            cellWidth: frameImage.width,
            cellHeight: frameImage.height,
            displaySize: displaySize,
            tolerance: tolerance,
            frameImage: frameImage
        )
        return Self.isHit(
            localPoint: localPoint, mask: mask, displaySize: displaySize,
            cellSize: CGSize(width: frameImage.width, height: frameImage.height),
            mirrored: snapshot.mirrored
        )
    }

    /// 清空缓存（资产替换 / 热更新后旧 mask 不得复用）。
    func clearCache() {
        maskCache.removeAll()
    }

    // MARK: - 判定

    /// 显示高度对应的容差（pt）。
    static func tolerance(forDisplayHeight height: CGFloat) -> CGFloat {
        height <= smallSizeCutoff ? smallTolerance : defaultTolerance
    }

    /// 窗口本地 pt → 帧像素网格命中查询。
    /// 坐标链：AppKit 本地点（y 向上）→ 归一化 → 帧像素（y 向下翻转；镜像时 x 反向）。
    private static func isHit(
        localPoint: CGPoint,
        mask: FrameMask,
        displaySize: CGSize,
        cellSize: CGSize,
        mirrored: Bool
    ) -> Bool {
        guard displaySize.width > 0, displaySize.height > 0,
              mask.width > 0, mask.height > 0 else { return true }
        // y 翻转：本地 y=0（窗口底）对应帧底行（行序数组中为最后一行）。
        var unitX = localPoint.x / displaySize.width
        let unitY = 1 - localPoint.y / displaySize.height
        if mirrored {
            unitX = 1 - unitX
        }
        let px = min(Int(unitX * CGFloat(mask.width)), mask.width - 1)
        let py = min(max(Int(unitY * CGFloat(mask.height)), 0), mask.height - 1)
        return mask.dilated[py * mask.width + px]
    }

    // MARK: - mask 构建

    /// 取（或构建）膨胀 mask：键含资产 / 帧 / 显示尺寸 / 容差（尺寸变化不复用错误 mask）。
    private func mask(
        assetID: String,
        frameIndex: Int,
        cellWidth: Int,
        cellHeight: Int,
        displaySize: CGSize,
        tolerance: CGFloat,
        frameImage: CGImage
    ) -> FrameMask {
        let key = "\(assetID)#\(frameIndex)#\(Int(displaySize.width))x\(Int(displaySize.height))#\(Int(tolerance))"
        if let cached = maskCache[key] { return cached }

        // 半径换算：显示 pt → 帧像素（非正方形时按显示宽与帧宽的比例）。
        let scaleX = CGFloat(cellWidth) / displaySize.width
        let scaleY = CGFloat(cellHeight) / displaySize.height
        let radius = max(1, Int((tolerance * min(scaleX, scaleY)).rounded()))

        var solid = [Bool](repeating: false, count: cellWidth * cellHeight)
        var buffer = [UInt8](repeating: 0, count: cellWidth * cellHeight * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: cellWidth,
                height: cellHeight,
                bitsPerComponent: 8,
                bytesPerRow: cellWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(frameImage, in: CGRect(x: 0, y: 0, width: cellWidth, height: cellHeight))
            return true
        }
        guard drawn else {
            // 读不出像素：退化为全命中（矩形兜底，不可操作比多穿透更糟）。
            let fallback = FrameMask(
                width: 1, height: 1, dilated: [true]
            )
            store(fallback, key: key)
            return fallback
        }
        for index in 0..<(cellWidth * cellHeight) where buffer[index * 4 + 3] > Self.alphaThreshold {
            solid[index] = true
        }

        // 圆核膨胀：任一实体像素距离 ≤ radius 即命中（完整邻域，非四点近似）。
        var dilated = [Bool](repeating: false, count: cellWidth * cellHeight)
        let radiusSquared = radius * radius
        for y in 0..<cellHeight {
            for x in 0..<cellWidth where solid[y * cellWidth + x] {
                let minY = max(0, y - radius), maxY = min(cellHeight - 1, y + radius)
                let minX = max(0, x - radius), maxX = min(cellWidth - 1, x + radius)
                for ny in minY...maxY {
                    for nx in minX...maxX {
                        let dx = nx - x, dy = ny - y
                        if dx * dx + dy * dy <= radiusSquared {
                            dilated[ny * cellWidth + nx] = true
                        }
                    }
                }
            }
        }
        let mask = FrameMask(width: cellWidth, height: cellHeight, dilated: dilated)
        store(mask, key: key)
        return mask
    }

    /// 缓存写入（有界：超限整体清空，LRU 不值得引入）。
    private func store(_ mask: FrameMask, key: String) {
        if maskCache.count >= Self.cacheLimit {
            maskCache.removeAll()
        }
        maskCache[key] = mask
    }
}
