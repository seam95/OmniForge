import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 截图输出图像质量档位。参照 capcap `ScreenshotImageQuality`。
enum ScreenshotImageQuality: String, CaseIterable, Sendable {
    /// 无损 PNG（保留 alpha）。
    case original
    /// 有损压缩 PNG（体积更小）。
    case compressed

    /// 默认值。
    static let defaultValue: ScreenshotImageQuality = .original

    /// 文件扩展名（不含前导点）。
    var fileExtension: String {
        switch self {
        case .original: return "png"
        case .compressed: return "png"
        }
    }

    /// MIME content type。
    var contentType: String { "image/png" }

    /// 对应的 `UTType`。
    var utType: UTType { .png }

    /// 是否走有损压缩路径。
    var usesLossyCompression: Bool { self == .compressed }
}

/// 编码后的图像输出。参照 capcap `EncodedImageOutput`。
struct EncodedImageOutput: Equatable {
    /// 编码后的二进制数据。
    let data: Data
    /// 文件扩展名（不含前导点）。
    let fileExtension: String
    /// MIME content type。
    let contentType: String
    /// 对应的 `UTType`。
    let contentTypeUTType: UTType
    /// 写入剪贴板时使用的 pasteboard 类型。
    let pasteboardType: NSPasteboard.PasteboardType
    /// 物理像素尺寸。
    let pixelSize: NSSize
}

/// 图像输出编码边界（供 Fake 替身）。
protocol ImageOutputEncoding: AnyObject {
    /// 同步编码。
    func encode(image: NSImage, quality: ScreenshotImageQuality) throws -> EncodedImageOutput
    /// 异步编码（后台编码，主线程回调）。
    func encodeAsync(
        image: NSImage,
        quality: ScreenshotImageQuality,
        completion: @escaping (Result<EncodedImageOutput, Error>) -> Void
    )
}

/// 图像输出编码错误。参照 capcap `ImageOutputEncodingError`。
enum ImageOutputEncodingError: Error, LocalizedError, Equatable {
    case missingImage
    case encoderUnavailable
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .missingImage: return "Could not read image data"
        case .encoderUnavailable: return "Image encoder unavailable"
        case .encodingFailed: return "Image encoding failed"
        }
    }
}

/// 生产实现：PNG/TIFF 编码、质量压缩、DPI 还原。
///
/// 参照 capcap `ImageOutputEncoder`（L98-158）。
/// 注：capcap 的手写 indexed PNG 编码器（median-cut + zlib + CRC32）非常复杂，
/// 这里采用简化版有损压缩（NSBitmapImageRep 降阶），保证协议边界正确、
/// PNG/TIFF 编码与 Retina DPI 还原到位即可。
final class ImageOutputEncoder: ImageOutputEncoding {
    private static let queue = DispatchQueue(label: "com.omniforge.image-output-encoder", qos: .userInitiated)

    /// 降阶色阶步长（有 alpha 分支用）。
    private static let quantizeSteps: [Int] = [6, 10]

    func encode(image: NSImage, quality: ScreenshotImageQuality) throws -> EncodedImageOutput {
        guard let source = ImageOutputSource(image: image) else {
            throw ImageOutputEncodingError.missingImage
        }
        let data: Data
        if quality == .compressed {
            data = try compressedPNGData(source: source)
        } else {
            data = try encodeImage(
                source.cgImage,
                typeIdentifier: UTType.png.identifier,
                pointSize: source.pointSize
            )
        }
        return EncodedImageOutput(
            data: data,
            fileExtension: quality.fileExtension,
            contentType: quality.contentType,
            contentTypeUTType: quality.utType,
            pasteboardType: .png,
            pixelSize: NSSize(width: source.cgImage.width, height: source.cgImage.height)
        )
    }

    func encodeAsync(
        image: NSImage,
        quality: ScreenshotImageQuality,
        completion: @escaping (Result<EncodedImageOutput, Error>) -> Void
    ) {
        guard let source = ImageOutputSource(image: image) else {
            completion(.failure(ImageOutputEncodingError.missingImage))
            return
        }
        Self.queue.async {
            let result = Result { try self.encode(source: source, quality: quality) }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    // MARK: - 内部

    /// 由 source 直接编码（避免再次构造 ImageOutputSource 校验）。
    private func encode(
        source: ImageOutputSource,
        quality: ScreenshotImageQuality
    ) throws -> EncodedImageOutput {
        let data: Data
        if quality == .compressed {
            data = try compressedPNGData(source: source)
        } else {
            data = try encodeImage(
                source.cgImage,
                typeIdentifier: UTType.png.identifier,
                pointSize: source.pointSize
            )
        }
        return EncodedImageOutput(
            data: data,
            fileExtension: quality.fileExtension,
            contentType: quality.contentType,
            contentTypeUTType: quality.utType,
            pasteboardType: .png,
            pixelSize: NSSize(width: source.cgImage.width, height: source.cgImage.height)
        )
    }

    /// ImageIO 编码：PNG 加 compression filter，按点尺寸还原 DPI（Retina 144）。
    /// 参照 capcap `encodeImage`（L98-129）。
    private func encodeImage(
        _ image: CGImage,
        typeIdentifier: String,
        pointSize: NSSize
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            typeIdentifier as CFString,
            1,
            nil
        ) else {
            throw ImageOutputEncodingError.encoderUnavailable
        }

        var properties: [CFString: Any] = [:]
        if typeIdentifier == UTType.png.identifier {
            properties[kCGImagePropertyPNGDictionary] = [
                kCGImagePropertyPNGCompressionFilter: 0xF8,
            ] as CFDictionary
        }
        if pointSize.width > 0, pointSize.height > 0 {
            properties[kCGImagePropertyDPIWidth] = Double(image.width) * 72.0 / Double(pointSize.width)
            properties[kCGImagePropertyDPIHeight] = Double(image.height) * 72.0 / Double(pointSize.height)
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageOutputEncodingError.encodingFailed
        }
        return data as Data
    }

    /// 简化版有损压缩：用 NSBitmapImageRep 降阶后再编码，取最小体积。
    /// 参照 capcap `compressedPNGData`（L131-158）思路；不实现手写 indexed PNG。
    private func compressedPNGData(source: ImageOutputSource) throws -> Data {
        var best = try encodeImage(
            source.cgImage,
            typeIdentifier: UTType.png.identifier,
            pointSize: source.pointSize
        )
        for step in Self.quantizeSteps {
            guard let quantized = quantizedCGImage(from: source.cgImage, colorStep: step) else { continue }
            let data = try encodeImage(
                quantized,
                typeIdentifier: UTType.png.identifier,
                pointSize: source.pointSize
            )
            if data.count < best.count {
                best = data
            }
        }
        return best
    }

    /// 色彩降阶生成新 CGImage（简化版 quantize）。
    private func quantizedCGImage(from image: CGImage, colorStep: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo
                  ) else { return }
            context.interpolationQuality = .none
            context.clear(rect)
            context.draw(image, in: rect)
        }

        let step = max(2, min(colorStep, 32))
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 {
                pixels[offset + channel] = quantizedChannel(pixels[offset + channel], step: step)
            }
        }

        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let quantized = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return nil
        }
        return quantized
    }

    private func quantizedChannel(_ value: UInt8, step: Int) -> UInt8 {
        guard value > 0, value < 255 else { return value }
        let rounded = ((Int(value) + step / 2) / step) * step
        return UInt8(min(255, max(0, rounded)))
    }
}

/// NSImage → CGImage + 点尺寸源（保留 backing，Retina 友好）。
/// 参照 capcap `ImageOutputSource`。
private struct ImageOutputSource {
    let cgImage: CGImage
    let pointSize: NSSize

    init?(image: NSImage) {
        // 优先取 backing CGImage（避免重采样丢失 Retina 像素）。
        if let cgImage = image.cgImagePreservingBacking() {
            self.cgImage = cgImage
            self.pointSize = image.size
            return
        }
        guard let rep = image.representations.first as? NSBitmapImageRep,
              let cgImage = rep.cgImage else {
            return nil
        }
        self.cgImage = cgImage
        self.pointSize = image.size
    }
}

// MARK: - NSImage backing 支持

/// 保留物理像素的 CGImage 提取（参照 capcap `cgImagePreservingBacking`）。
/// OmniForge 无此扩展，这里就近补充。
extension NSImage {
    /// 取最高分辨率 NSBitmapImageRep 的 CGImage；回退到 cgImage(forProposedRect:)。
    func cgImagePreservingBacking() -> CGImage? {
        let highestRes = representations
            .compactMap { $0 as? NSBitmapImageRep }
            .filter { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }
            .max { lhs, rhs in
                (lhs.pixelsWide * lhs.pixelsHigh) < (rhs.pixelsWide * rhs.pixelsHigh)
            }
        if let cgImage = highestRes?.cgImage {
            return cgImage
        }
        var proposedRect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }
}
