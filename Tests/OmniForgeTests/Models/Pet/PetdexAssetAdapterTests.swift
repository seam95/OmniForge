import AppKit
import XCTest
@testable import OmniForge

/// petdex 资产适配器测试：行映射、逐行扫帧、非正方形网格、错误分类。
final class PetdexAssetAdapterTests: XCTestCase {
    private var workDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("petdex-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - 构造测试宠物

    /// 生成一张 8×9 图集：按 `framesByRow` 指定每行前 N 格填不透明色，其余透明。
    /// 单元格尺寸可指定（用于验证非正方形）。
    private func makePet(
        slug: String,
        framesByRow: [Int: Int],
        cellWidth: Int = 24,
        cellHeight: Int = 26,
        version: Int? = nil,
        atlasRows: Int = 9,
        declaredSheetName: String = "spritesheet.png"
    ) throws -> URL {
        let directory = workDirectory.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let columns = 8
        let rows = atlasRows
        let width = columns * cellWidth
        let height = rows * cellHeight

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
            context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
            for (row, count) in framesByRow {
                for column in 0..<count {
                    // CGContext 原点在左下，makeImage 不翻转；用低 y 填充即对应
                    // 适配器扫描约定的图集行（与真实 top-down PNG 对齐后的结果一致）。
                    let x = column * cellWidth
                    let y = row * cellHeight
                    context.fill(CGRect(x: x, y: y, width: cellWidth, height: cellHeight))
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

        var manifest: [String: Any] = [
            "id": slug,
            "displayName": slug.capitalized,
            "spritesheetPath": declaredSheetName,
        ]
        if let version { manifest["spriteVersionNumber"] = version }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("pet.json"))
        return directory
    }

    // MARK: - 正常路径

    func test_loadMapsRowsToAnimationsAndScansFrames() throws {
        // row0=6 帧 idle、row1=6 帧右行、row2=6 帧左行、row3=4 帧抚摸、row4=5 帧悬空。
        let directory = try makePet(
            slug: "tester",
            framesByRow: [0: 6, 1: 6, 2: 6, 3: 4, 4: 5]
        )

        let asset = try PetdexAssetAdapter.load(from: directory)

        XCTAssertEqual(asset.id, "tester")
        XCTAssertEqual(asset.grid.columns, 8)
        XCTAssertEqual(asset.grid.rows, 9)
        XCTAssertEqual(asset.grid.cellWidth, 24)
        XCTAssertEqual(asset.grid.cellHeight, 26)

        XCTAssertEqual(asset.animation(id: PetAnimationID.idle)?.frames, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(asset.animation(id: PetAnimationID.walkRight)?.frames, [8, 9, 10, 11, 12, 13])
        XCTAssertEqual(asset.animation(id: PetAnimationID.walkLeft)?.frames, [16, 17, 18, 19, 20, 21])
        XCTAssertEqual(asset.animation(id: PetAnimationID.petted)?.frames, [24, 25, 26, 27])
        XCTAssertEqual(asset.animation(id: PetAnimationID.drag)?.frames, [32, 33, 34, 35, 36])
    }

    func test_loadComputesNonSquareAspectRatio() throws {
        let directory = try makePet(slug: "ratio", framesByRow: [0: 2], cellWidth: 24, cellHeight: 26)

        let asset = try PetdexAssetAdapter.load(from: directory)

        XCTAssertEqual(asset.aspectRatio, 24.0 / 26.0, accuracy: 0.0001)
    }

    func test_loadSkipsEmptyRows() throws {
        // 只填 row0 与 row3，中间空行不应产生动画。
        let directory = try makePet(slug: "sparse", framesByRow: [0: 3, 3: 2])

        let asset = try PetdexAssetAdapter.load(from: directory)

        XCTAssertNotNil(asset.animation(id: PetAnimationID.idle))
        XCTAssertNotNil(asset.animation(id: PetAnimationID.petted))
        XCTAssertNil(asset.animation(id: PetAnimationID.walkRight))
        XCTAssertNil(asset.animation(id: PetAnimationID.drag))
    }

    func test_pettedAnimationIsNonLooping() throws {
        let directory = try makePet(slug: "loop", framesByRow: [0: 2, 3: 2])

        let asset = try PetdexAssetAdapter.load(from: directory)

        XCTAssertEqual(asset.animation(id: PetAnimationID.petted)?.loops, false)
        XCTAssertEqual(asset.animation(id: PetAnimationID.idle)?.loops, true)
    }

    func test_idleFallsBackToFirstRowWhenIdleRowEmpty() throws {
        // row0 空、row1 有内容：应把首个可用行兜底为 idle 素材。
        let directory = try makePet(slug: "fallback", framesByRow: [1: 4])

        let asset = try PetdexAssetAdapter.load(from: directory)

        XCTAssertEqual(asset.animation(id: PetAnimationID.idle)?.frames, [8, 9, 10, 11])
    }

    func test_loadKeepsAgentStateRowsForPhaseTwo() throws {
        // row5/6/8 语义行保留，供二期接 Agent 状态反应。
        let directory = try makePet(slug: "agent", framesByRow: [0: 2, 5: 2, 6: 2, 8: 3])

        let asset = try PetdexAssetAdapter.load(from: directory)

        XCTAssertNotNil(asset.animation(id: PetAnimationID.failed))
        XCTAssertNotNil(asset.animation(id: PetAnimationID.waiting))
        XCTAssertNotNil(asset.animation(id: PetAnimationID.review))
    }

    // MARK: - 错误路径

    func test_loadRejectsMissingManifest() throws {
        let directory = workDirectory.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertThrowsError(try PetdexAssetAdapter.load(from: directory)) { error in
            XCTAssertEqual(error as? PetdexAssetError, .missingPetJSON)
        }
    }

    func test_loadRejectsMissingSpritesheet() throws {
        let directory = workDirectory.appendingPathComponent("nosheet", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"id":"x","displayName":"X"}"#.utf8)
            .write(to: directory.appendingPathComponent("pet.json"))

        XCTAssertThrowsError(try PetdexAssetAdapter.load(from: directory)) { error in
            XCTAssertEqual(error as? PetdexAssetError, .missingSpritesheet)
        }
    }

    func test_loadSupportsV2AtlasWithElevenRows() throws {
        // v2（8×11）图集：前 9 行同 v1 语义，扫描与裁剪按 11 物理行。
        // pet.json 的版本字段不可靠，适配以图集实际尺寸为准。
        let directory = try makePet(
            slug: "v2pet",
            framesByRow: [0: 3],
            cellWidth: 24,
            cellHeight: 26,
            version: 2,
            atlasRows: 11
        )

        let asset = try PetdexAssetAdapter.load(from: directory)

        XCTAssertEqual(asset.grid.rows, 11)
        XCTAssertEqual(asset.grid.cellHeight, 26)
        XCTAssertEqual(asset.animation(id: PetAnimationID.idle)?.frames, [0, 1, 2])
    }

    // MARK: - 真实资产（网络产物已缓存时）

    func test_realPetdexAssetIfCached() throws {
        // 端到端：若本机缓存了真实 petdex 图集则校验适配结果，否则跳过。
        let cached = URL(fileURLWithPath: "/tmp/sprite_v1.webp")
        guard FileManager.default.fileExists(atPath: cached.path) else {
            throw XCTSkip("未缓存真实 petdex 图集，跳过端到端校验")
        }
        // 真实布局：1536×1872 = 8×9，单元格 192×208。
        let directory = workDirectory.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: cached,
            to: directory.appendingPathComponent("spritesheet.webp")
        )
        try Data(#"{"id":"real","displayName":"Real","spritesheetPath":"spritesheet.webp"}"#.utf8)
            .write(to: directory.appendingPathComponent("pet.json"))

        let asset = try PetdexAssetAdapter.load(from: directory)

        XCTAssertEqual(asset.grid.cellWidth, 192)
        XCTAssertEqual(asset.grid.cellHeight, 208)
        XCTAssertNotNil(asset.animation(id: PetAnimationID.idle))
        XCTAssertFalse(asset.animation(id: PetAnimationID.idle)?.frames.isEmpty ?? true)
    }
}
