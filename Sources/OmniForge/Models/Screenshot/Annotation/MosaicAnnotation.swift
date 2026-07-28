import AppKit
import CoreImage
import Foundation

/// 马赛克标注。参照 capcap `MosaicAnnotation` + `MosaicTool`：
/// 构造期对底图指定**矩形区域**应用 CIPixellate 像素化，draw 只绘位图。
struct MosaicAnnotation: Annotation, Equatable {
    let uuid: UUID
    var rect: NSRect
    var blockSize: CGFloat
    /// 预像素化后的位图（构造期生成）。
    var pixelatedImage: NSImage?
    let supportsRotation: Bool = false
    var rotation: CGFloat { 0 }

    init(uuid: UUID = UUID(), rect: NSRect, blockSize: CGFloat = 12, sourceImage: NSImage? = nil, imageSize: NSSize = .zero) {
        self.uuid = uuid
        self.rect = rect
        self.blockSize = blockSize
        self.pixelatedImage = sourceImage.flatMap {
            MosaicTool.createMosaicRegion(rect: rect, imageSize: imageSize, baseImage: $0, blockSize: blockSize)?.pixelatedImage
        }
    }

    /// 直接传入已像素化位图（用于画布交互中 resize 后重新像素化）。
    init(uuid: UUID = UUID(), rect: NSRect, pixelatedImage: NSImage, blockSize: CGFloat) {
        self.uuid = uuid
        self.rect = rect
        self.blockSize = blockSize
        self.pixelatedImage = pixelatedImage
    }

    func draw(in context: CGContext, bounds: NSRect) {
        if let image = pixelatedImage {
            image.draw(in: rect)
        } else {
            // 无像素化图像时绘制半透明灰色占位（绘制预览）。
            context.setFillColor(NSColor.gray.withAlphaComponent(0.5).cgColor)
            context.fill(rect)
        }
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        rect.insetBy(dx: -strokeHitTolerance, dy: -strokeHitTolerance).contains(point)
    }

    func translated(by delta: NSPoint) -> Annotation {
        var copy = self
        copy.rect = rect.offsetBy(dx: delta.x, dy: delta.y)
        return copy
    }

    var boundingRect: NSRect { rect }

    func withColor(_ color: NSColor) -> Annotation { self }
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation { self }

    /// 调整模式：替换矩形（保持原像素位图）。
    func withRect(_ rect: NSRect) -> MosaicAnnotation {
        MosaicAnnotation(uuid: uuid, rect: rect, pixelatedImage: pixelatedImage ?? NSImage(), blockSize: blockSize)
    }
}

/// 马赛克区域像素化工具。参照 capcap `MosaicTool`：
/// 把底图按 `rect` 裁剪（Y 翻转转 CG 坐标），用 CIPixellate 像素化。
struct MosaicRegion: Equatable {
    let rect: NSRect
    let pixelatedImage: NSImage
}

struct MosaicTool {
    /// 把 `baseImage` 中 `rect`（拖拽矩形）区域像素化。
    /// 返回裁剪到图像 bounds 内的像素化区域，失败返回 nil。
    static func createMosaicRegion(
        rect: NSRect,
        imageSize: NSSize,
        baseImage: NSImage,
        blockSize: CGFloat = 12
    ) -> MosaicRegion? {
        // 把拖拽矩形夹取到图像 bounds 内。
        let clamped = rect.intersection(NSRect(origin: .zero, size: imageSize))
        guard clamped.width > 0, clamped.height > 0 else { return nil }

        guard let cgImage = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        // 转换到 CG 坐标系（翻转 Y）。
        let scale = CGFloat(cgImage.width) / imageSize.width
        let cgRegion = CGRect(
            x: clamped.origin.x * scale,
            y: (imageSize.height - clamped.origin.y - clamped.height) * scale,
            width: clamped.width * scale,
            height: clamped.height * scale
        )

        guard let croppedCG = cgImage.cropping(to: cgRegion) else { return nil }

        // CIPixellate 像素化，块大小不小于 4。
        let ciImage = CIImage(cgImage: croppedCG)
        guard let pixelateFilter = CIFilter(name: "CIPixellate") else { return nil }
        pixelateFilter.setValue(ciImage, forKey: kCIInputImageKey)
        pixelateFilter.setValue(max(blockSize, 4), forKey: kCIInputScaleKey)
        pixelateFilter.setValue(CIVector(x: ciImage.extent.midX, y: ciImage.extent.midY), forKey: kCIInputCenterKey)

        guard let outputCI = pixelateFilter.outputImage else { return nil }
        let ciContext = CIContext()
        guard let outputCG = ciContext.createCGImage(outputCI, from: ciImage.extent) else { return nil }

        let pixelatedImage = NSImage(cgImage: outputCG, size: clamped.size)
        return MosaicRegion(rect: clamped, pixelatedImage: pixelatedImage)
    }
}
