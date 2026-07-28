import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes BGRA pixel buffers into an animated GIF, thinning frames from source FPS down to target FPS (≤ 15).
final class GIFEncoder {
    private let url: URL
    private let targetFPS: Int
    private let sourceEstimatedFPS: Int
    private let frameProperties: [CFString: Any]
    private let gifProperties: [CFString: Any]
    private var destination: CGImageDestination?
    private var inputFrameCount = 0
    private var frameCount = 0
    private let lock = NSLock()

    init(url: URL, fps: Int, sourceFPS: Int) {
        self.url = url
        self.targetFPS = min(max(fps, 1), 15)
        self.sourceEstimatedFPS = max(sourceFPS, self.targetFPS)

        let delayTime = 1.0 / Float(self.targetFPS)
        // Loop count belongs on destination properties only; per-frame dict is delay.
        frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delayTime,
            ] as [CFString: Any]
        ]
        gifProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
            ] as [CFString: Any]
        ]

        destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            Int.max,
            nil
        )
        if let destination {
            CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)
        }
    }

    /// Target FPS after clamping (1…15). Useful for tests.
    var clampedTargetFPS: Int { targetFPS }

    func addFrame(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        defer { lock.unlock() }

        inputFrameCount += 1
        let keepEvery = max(1, sourceEstimatedFPS / targetFPS)
        guard (inputFrameCount - 1) % keepEvery == 0 else { return }
        guard let destination else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return }

        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let sourceContext = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let sourceImage = sourceContext.makeImage() else {
            return
        }

        guard let ownedContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return }
        ownedContext.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let ownedImage = ownedContext.makeImage() else { return }

        CGImageDestinationAddImage(destination, ownedImage, frameProperties as CFDictionary)
        frameCount += 1
    }

    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let destination, frameCount > 0 else { return false }
        let ok = CGImageDestinationFinalize(destination)
        self.destination = nil
        return ok
    }
}
