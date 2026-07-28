import AppKit
import ImageIO

enum ClipboardImageDownsampler {
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
