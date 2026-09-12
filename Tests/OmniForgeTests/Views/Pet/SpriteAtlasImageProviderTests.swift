import AppKit
import XCTest
@testable import OmniForge

/// 图集切片器测试：锁住「裁剪帧 == 适配器占用扫描判定的同一格」这一坐标契约。
/// 历史回归：旧实现走 NSImage.draw(from:)，webp 位图表示的坐标系与 PNG 相反，
/// 社区宠物裁到镜像行内容——抚摸动画尾帧落空、宠物消失约半秒。
@MainActor
final class SpriteAtlasImageProviderTests: XCTestCase {
    private var workDirectory: URL!
    private var previousRoots: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-sprite-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        previousRoots = PetAssetLocator.additionalSearchRoots
        PetAssetLocator.additionalSearchRoots = [workDirectory]
        SpriteAtlasImageProvider.shared.clearCache()
    }

    override func tearDownWithError() throws {
        SpriteAtlasImageProvider.shared.clearCache()
        PetAssetLocator.additionalSearchRoots = previousRoots
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - 构造测试图集

    /// 生成 8×9 图集：每格填独特色（R=行、G=列编码），并落盘 pet.json 占位。
    /// 填充手法与 PetdexAssetAdapterTests 相同（CG 低 y = 逻辑行 row），
    /// 保证与适配器占用扫描同一条像素链路。
    private func makeColorCodedAsset(slug: String) throws -> PetSpriteAsset {
        let directory = workDirectory.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "{}".data(using: .utf8)!.write(to: directory.appendingPathComponent("pet.json"))

        let columns = 8, rows = 9, cellWidth = 12, cellHeight = 14
        let width = columns * cellWidth, height = rows * cellHeight
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            for row in 0..<rows {
                for column in 0..<columns {
                    // 颜色编码：R=40+行×20（唯一识别行），G=20+列×25（唯一识别列）。
                    context.setFillColor(CGColor(
                        srgbRed: Double(40 + row * 20) / 255.0,
                        green: Double(20 + column * 25) / 255.0,
                        blue: 0.3,
                        alpha: 1
                    ))
                    context.fill(CGRect(
                        x: column * cellWidth,
                        y: row * cellHeight,
                        width: cellWidth,
                        height: cellHeight
                    ))
                }
            }
        }
        let image: CGImage? = buffer.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        let png = try XCTUnwrap(image.flatMap {
            NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:])
        })
        try png.write(to: directory.appendingPathComponent("spritesheet.png"))

        return PetSpriteAsset(
            id: slug,
            displayName: slug,
            atlasFileName: "spritesheet.png",
            grid: PetSpriteAsset.Grid(
                columns: columns,
                rows: rows,
                cellWidth: cellWidth,
                cellHeight: cellHeight
            ),
            animations: [
                PetSpriteAsset.Animation(
                    id: PetAnimationID.idle,
                    frames: Array(0..<columns),
                    fps: 4,
                    loops: true,
                    mirrorX: false
                )
            ]
        )
    }

    /// 读取裁出帧中心像素颜色。
    private func centerPixel(of image: NSImage) -> (r: Int, g: Int, b: Int)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let w = cg.width, h = cg.height
        var buffer = [UInt8](repeating: 0, count: max(1, w * h * 4))
        guard let context = CGContext(
            data: &buffer,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: max(1, w * 4),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let index = ((h / 2) * w + (w / 2)) * 4
        return (Int(buffer[index]), Int(buffer[index + 1]), Int(buffer[index + 2]))
    }

    // MARK: - 坐标契约

    /// 帧序号 → 裁出内容必须落在 (行, 列) 对应的格子上：行不镜像、列不偏移。
    /// 这正是抚摸消失回归的根因护栏（webp 镜像裁剪曾让 petted 尾帧落空）。
    func testCropMatchesScanGridConvention() throws {
        let asset = try makeColorCodedAsset(slug: "coord-pet")

        // 抽查行 0 / 3 / 8（首、中、尾）× 全部列，断言颜色编码匹配 (行, 列)。
        for row in [0, 3, 8] {
            for column in 0..<8 {
                let frameIndex = row * 8 + column
                let image = try XCTUnwrap(
                    SpriteAtlasImageProvider.shared.image(asset: asset, frameIndex: frameIndex),
                    "帧 \(frameIndex) 应裁出内容"
                )
                let pixel = try XCTUnwrap(centerPixel(of: image))
                XCTAssertEqual(pixel.r, 40 + row * 20, accuracy: 3,
                               "帧 \(frameIndex) 的行编码不符（疑似行镜像/偏移）")
                XCTAssertEqual(pixel.g, 20 + column * 25, accuracy: 3,
                               "帧 \(frameIndex) 的列编码不符（疑似列偏移）")
            }
        }
    }

    /// 帧缓存生效：同帧两次请求返回同一实例。
    func testFrameCacheReusesInstance() throws {
        let asset = try makeColorCodedAsset(slug: "cache-pet")
        let first = try XCTUnwrap(
            SpriteAtlasImageProvider.shared.image(asset: asset, frameIndex: 0)
        )
        let second = try XCTUnwrap(
            SpriteAtlasImageProvider.shared.image(asset: asset, frameIndex: 0)
        )
        XCTAssertTrue(first === second)
    }

    /// 越界帧序号返回 nil（不崩溃）。
    func testOutOfRangeFrameIndexReturnsNil() throws {
        let asset = try makeColorCodedAsset(slug: "bounds-pet")
        XCTAssertNil(SpriteAtlasImageProvider.shared.image(asset: asset, frameIndex: -1))
        XCTAssertNil(SpriteAtlasImageProvider.shared.image(asset: asset, frameIndex: 8 * 9))
    }
}
