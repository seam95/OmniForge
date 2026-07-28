import AppKit
import Foundation
@testable import OmniForge

// MARK: - ImageOutputEncoding fake

/// 参照 KeepAwake 范式：private(set) 副作用计数 + 失败注入。
final class FakeImageOutputEncoder: ImageOutputEncoding {
    struct EncodeCall: Equatable {
        let pixelSize: NSSize
        let quality: ScreenshotImageQuality
        /// 传入 image 最高分辨率 representation 的像素宽（验证合成密度）。
        let pixelsWide: Int
    }

    private(set) var syncCalls: [EncodeCall] = []
    private(set) var asyncCalls: [EncodeCall] = []
    /// 同步编码返回的固定 payload（默认 1×1 PNG 占位）。
    var stubbedOutput: EncodedImageOutput = FakeImageOutputEncoder.placeholderPNG()
    /// 设置后同步 encode 抛错；async 走 .failure。
    var errorToThrow: Error?

    func encode(image: NSImage, quality: ScreenshotImageQuality) throws -> EncodedImageOutput {
        let size = NSSize(width: image.size.width, height: image.size.height)
        syncCalls.append(EncodeCall(pixelSize: size, quality: quality, pixelsWide: FakeImageOutputEncoder.maxPixelsWide(of: image)))
        if let errorToThrow { throw errorToThrow }
        return stubbedOutput
    }

    func encodeAsync(
        image: NSImage,
        quality: ScreenshotImageQuality,
        completion: @escaping (Result<EncodedImageOutput, Error>) -> Void
    ) {
        let size = NSSize(width: image.size.width, height: image.size.height)
        asyncCalls.append(EncodeCall(pixelSize: size, quality: quality, pixelsWide: FakeImageOutputEncoder.maxPixelsWide(of: image)))
        if let errorToThrow {
            completion(.failure(errorToThrow))
        } else {
            completion(.success(stubbedOutput))
        }
    }

    private static func placeholderPNG() -> EncodedImageOutput {
        FakeImageOutputEncoder.makePlaceholderPNG()
    }

    /// 取 image 最高分辨率 NSBitmapImageRep 的像素宽（无则 0）。
    private static func maxPixelsWide(of image: NSImage) -> Int {
        image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .map(\.pixelsWide)
            .filter { $0 > 0 }
            .max() ?? 0
    }

    static func makePlaceholderPNG() -> EncodedImageOutput {
        // 1×1 透明 PNG（合法 payload，非空）。
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: 1,
                                   pixelsHigh: 1,
                                   bitsPerSample: 8,
                                   samplesPerPixel: 4,
                                   hasAlpha: true,
                                   isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 4,
                                   bitsPerPixel: 32)
        let data = rep?.tiffRepresentation ?? Data()
        return EncodedImageOutput(
            data: data.isEmpty ? Data([0x89]) : data,
            fileExtension: "png",
            contentType: "image/png",
            contentTypeUTType: .png,
            pasteboardType: .png,
            pixelSize: NSSize(width: 1, height: 1)
        )
    }
}

// MARK: - ClipboardImageWriting fake

final class FakeClipboardImageWriter: ClipboardImageWriting {
    private(set) var writes: [EncodedImageOutput] = []
    /// 控制下次 writeImage 返回值（默认成功）。
    var nextResult: Bool = true

    @discardableResult
    func writeImage(_ output: EncodedImageOutput) -> Bool {
        writes.append(output)
        let result = nextResult
        return result
    }
}

// MARK: - ScreenshotSaving fake

final class FakeScreenshotSaver: ScreenshotSaving {
    struct SaveCall: Equatable {
        let output: EncodedImageOutput
        let quality: ScreenshotImageQuality
        let fileName: String?
        let directory: URL?
    }

    private(set) var calls: [SaveCall] = []
    /// 返回的 URL（默认临时文件）；设置 errorToThrow 则抛错。
    var stubbedURL: URL = URL(fileURLWithPath: "/tmp/Screenshot-test.png")
    var errorToThrow: Error?

    func save(
        output: EncodedImageOutput,
        quality: ScreenshotImageQuality,
        fileName: String?,
        directory: URL?
    ) throws -> URL {
        calls.append(SaveCall(output: output, quality: quality, fileName: fileName, directory: directory))
        if let errorToThrow { throw errorToThrow }
        return stubbedURL
    }
}

// MARK: - ScreenshotPinning fake

final class FakePinService: ScreenshotPinning {
    private(set) var pinnedResults: [ScreenshotResult] = []
    /// 每次钉住调用传入的屏幕原点（与 pinnedResults 同序）。
    private(set) var pinnedOrigins: [NSPoint?] = []
    /// 设置后 pinFromPipeline 抛错。
    var errorToThrow: Error?
    /// 下一个返回的 id（每次自增）。
    private var nextID = UUID()

    @discardableResult
    func pinFromPipeline(result: ScreenshotResult, at origin: NSPoint?) throws -> UUID {
        pinnedResults.append(result)
        pinnedOrigins.append(origin)
        if let errorToThrow { throw errorToThrow }
        let id = nextID
        nextID = UUID()
        return id
    }
}
