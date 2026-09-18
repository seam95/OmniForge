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
    /// 填充手法与 PetdexAssetAdapterTests 相同（逻辑行 0 = 文件顶部行，Quartz 高 y），
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
                    // 图集约定：逻辑行 0 = 文件顶部行。CGBitmapContext 缓冲行 0
                    // 对应 Quartz 顶部（高 y），故逻辑行 row 填在高 y 区域。
                    context.setFillColor(CGColor(
                        srgbRed: Double(40 + row * 20) / 255.0,
                        green: Double(20 + column * 25) / 255.0,
                        blue: 0.3,
                        alpha: 1
                    ))
                    context.fill(CGRect(
                        x: column * cellWidth,
                        y: (rows - 1 - row) * cellHeight,
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

    /// webp 版颜色编码图集：与 `makeColorCodedAsset` 同一张图的无损 webp 编码
    /// （8×9、cell 12×14，R=行编码 G=列编码，逻辑行 0 = 文件顶部）。
    /// webp 无法运行时编码（ImageIO 不支持），以 base64 内嵌（84 字节）。
    private func makeWebpColorCodedAsset(slug: String) throws -> PetSpriteAsset {
        let directory = workDirectory.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "{}".data(using: .utf8)!.write(to: directory.appendingPathComponent("pet.json"))
        // swiftlint:disable:next line_length
        let base64 = "UklGRkwAAABXRUJQVlA4TD8AAAAvX0AfALkyRPQ/dhHR/4CatpGYA3Hf+HP96cYvAoEUBzHE0xRk0jargV0RwYOuQujDpAuR3/vv9oHm9vvvNgAA"
        let webp = try XCTUnwrap(Data(base64Encoded: base64), "webp fixture base64 解码失败")
        try webp.write(to: directory.appendingPathComponent("spritesheet.webp"))

        return PetSpriteAsset(
            id: slug,
            displayName: slug,
            atlasFileName: "spritesheet.webp",
            grid: PetSpriteAsset.Grid(
                columns: 8,
                rows: 9,
                cellWidth: 12,
                cellHeight: 14
            ),
            animations: [
                PetSpriteAsset.Animation(
                    id: PetAnimationID.idle,
                    frames: Array(0..<8),
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

    /// webp 坐标契约：真实 webp 解码路径下，帧序号 → 行/列编码必须与 PNG 一致。
    /// 历史回归（36e8995 引入）：webp 解码位图在「CGContext.draw 整图进缓冲」路径下
    /// 缓冲行序与 PNG 相反，整张图集行映射上下翻转——idle 实际播到 review 行内容
    /// （社区宠物反复做 review 动作）。PNG 契约测试覆盖不到该路径，必须用真 webp。
    func testCropMatchesScanGridConvention_webp() throws {
        let asset = try makeWebpColorCodedAsset(slug: "coord-pet-webp")

        for row in [0, 3, 8] {
            for column in 0..<8 {
                let frameIndex = row * 8 + column
                let image = try XCTUnwrap(
                    SpriteAtlasImageProvider.shared.image(asset: asset, frameIndex: frameIndex),
                    "帧 \(frameIndex) 应裁出内容"
                )
                let pixel = try XCTUnwrap(centerPixel(of: image))
                XCTAssertEqual(pixel.r, 40 + row * 20, accuracy: 3,
                               "webp 帧 \(frameIndex) 的行编码不符（疑似行镜像/偏移）")
                XCTAssertEqual(pixel.g, 20 + column * 25, accuracy: 3,
                               "webp 帧 \(frameIndex) 的列编码不符（疑似列偏移）")
            }
        }
    }

    /// 帧缓存生效：同帧两次请求复用同一 CGImage 裁剪结果
    /// （渲染 NSImage 与命中层共享同一份缓存——NSImage 是轻包装，实例不必相同）。
    func testFrameCacheReusesInstance() throws {
        let asset = try makeColorCodedAsset(slug: "cache-pet")
        let first = try XCTUnwrap(
            SpriteAtlasImageProvider.shared.frameCGImage(asset: asset, frameIndex: 0)
        )
        let second = try XCTUnwrap(
            SpriteAtlasImageProvider.shared.frameCGImage(asset: asset, frameIndex: 0)
        )
        XCTAssertTrue(first === second, "同帧两次请求应复用同一 CGImage 裁剪结果")
    }

    /// 越界帧序号返回 nil（不崩溃）。
    func testOutOfRangeFrameIndexReturnsNil() throws {
        let asset = try makeColorCodedAsset(slug: "bounds-pet")
        XCTAssertNil(SpriteAtlasImageProvider.shared.image(asset: asset, frameIndex: -1))
        XCTAssertNil(SpriteAtlasImageProvider.shared.image(asset: asset, frameIndex: 8 * 9))
    }

    // MARK: - 图集缓存 LRU 上限

    /// 图集缓存 LRU 上限回归：超限逐出最久未用的资产；活跃资产命中续期不逐出；
    /// 被逐资产的帧切片连带清除（切片强持有父图集 backing，残留即白逐出——
    /// 若未连带清除，被逐资产请求帧时直接命中旧切片、不再触发解码）。
    /// 历史回归：无上限图集缓存曾随宠物切换无限累积（一天 38 张 ≈ 417MB）。
    func testAtlasCacheEvictsLeastRecentlyUsedAsset() throws {
        let petA = try makeColorCodedAsset(slug: "lru-pet-a")
        let petB = try makeColorCodedAsset(slug: "lru-pet-b")
        let petC = try makeColorCodedAsset(slug: "lru-pet-c")
        let petD = try makeColorCodedAsset(slug: "lru-pet-d")

        var decodeCount = 0
        let provider = SpriteAtlasImageProvider(decodeAtlas: { url in
            decodeCount += 1
            return SpriteAtlasImageProvider.defaultAtlasDecoder(url: url)
        })

        func requestFrame0(_ asset: PetSpriteAsset) throws -> CGImage {
            try XCTUnwrap(provider.frameCGImage(asset: asset, frameIndex: 0))
        }

        // 填满上限（3）：A、B、C 各解码一次。
        _ = try requestFrame0(petA)
        _ = try requestFrame0(petB)
        _ = try requestFrame0(petC)
        XCTAssertEqual(decodeCount, 3, "三只不同宠物各应解码一次")

        // A 命中续期（LRU 序移尾），不产生新解码。
        _ = try requestFrame0(petA)
        XCTAssertEqual(decodeCount, 3, "缓存内资产命中不得重新解码")

        // D 进入超限：应逐出最久未用的 B（而非续期过的 A）。
        _ = try requestFrame0(petD)
        XCTAssertEqual(decodeCount, 4, "第四只宠物应触发解码并逐出最久未用资产")

        // A 仍在缓存（续期生效）。
        _ = try requestFrame0(petA)
        XCTAssertEqual(decodeCount, 4, "续期过的活跃资产不得被逐出")

        // B 已被逐（含帧切片）：再次请求必须重新解码。
        _ = try requestFrame0(petB)
        XCTAssertEqual(decodeCount, 5, "被逐资产的帧切片应连带清除，再请求须重新解码")
    }

    /// 缓存上限内多资产共存：不误逐、不重复解码。
    func testAtlasCacheHoldsAssetsUpToLimit() throws {
        let pets = try (0..<SpriteAtlasImageProvider.atlasCacheLimit).map {
            try makeColorCodedAsset(slug: "limit-pet-\($0)")
        }
        var decodeCount = 0
        let provider = SpriteAtlasImageProvider(decodeAtlas: { url in
            decodeCount += 1
            return SpriteAtlasImageProvider.defaultAtlasDecoder(url: url)
        })

        for asset in pets { _ = try XCTUnwrap(provider.frameCGImage(asset: asset, frameIndex: 0)) }
        XCTAssertEqual(decodeCount, pets.count, "上限内资产各解码一次")

        for asset in pets {
            let frame = try XCTUnwrap(provider.frameCGImage(asset: asset, frameIndex: 1))
            XCTAssertEqual(frame.width, 12)
        }
        XCTAssertEqual(decodeCount, pets.count, "上限内资产二次请求不同帧不得重新解码图集")
    }
}
