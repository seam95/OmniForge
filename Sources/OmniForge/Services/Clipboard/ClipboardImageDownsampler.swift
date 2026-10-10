import AppKit
import ImageIO

enum ClipboardImageDownsampler {
    /// 数据是否是可解码的图片（ImageIO 能建源）。
    /// 某些应用（如微信）在 .png 槽位只放几字节占位符，建源必败——
    /// 采集与装载都以它为准，避免存入永远无法预览的条目。
    static func isDecodable(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return false
        }
        return CGImageSourceGetCount(source) > 0
    }

    static func image(data: Data, maxPixelSize: Int) -> NSImage? {
        guard maxPixelSize > 0 else { return nil }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }

        let representation = NSBitmapImageRep(cgImage: image)
        let result = NSImage(
            size: NSSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        )
        result.addRepresentation(representation)
        return result
    }
}
