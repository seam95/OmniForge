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
                    // 图集约定：逻辑行 0 = 文件顶部行。CGBitmapContext 缓冲行 0
                    // 对应 Quartz 顶部（高 y），故逻辑行 row 填在高 y 区域。
                    let x = column * cellWidth
                    let y = (rows - 1 - row) * cellHeight
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

    /// webp 行序契约：真实 webp 解码路径下，逻辑行 0（idle）必须扫到文件顶部行段。
    /// 历史回归（36e8995 引入）：webp 解码位图在「CGContext.draw 整图进缓冲」路径下
    /// 缓冲行序与 PNG 相反，行映射整体上下翻转——idle 扫到 review 行，
    /// 社区宠物静止时反复播 review 动作。PNG 用例覆盖不到，必须用真 webp。
    /// fixture 为无损 webp（58 字节 base64 内嵌）：逻辑行 0 填 3 格、逻辑行 8 填 5 格。
    func test_loadWebpScansTopRowAsIdle() throws {
        let directory = workDirectory.appendingPathComponent("webper", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // swiftlint:disable:next line_length
        let base64 = "UklGRjIAAABXRUJQVlA4TCUAAAAvX0AfEA8wk/Mf8x84zLRtEwblj9YMdu2I6P8EwKqqq3yngN0HAA=="
        let webp = try XCTUnwrap(Data(base64Encoded: base64), "webp fixture base64 解码失败")
        try webp.write(to: directory.appendingPathComponent("spritesheet.webp"))
        let manifest: [String: Any] = ["id": "webper", "displayName": "Webper", "spritesheetPath": "spritesheet.webp"]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("pet.json"))

        let asset = try PetdexAssetAdapter.load(from: directory)

        // 行 0（idle）3 帧、行 8（review）5 帧；翻转时会扫反或触发 idle 兜底。
        XCTAssertEqual(asset.animation(id: PetAnimationID.idle)?.frames, [0, 1, 2],
                       "webp 的 idle 行扫描不符（疑似行镜像）")
        XCTAssertEqual(asset.animation(id: PetAnimationID.review)?.frames, [64, 65, 66, 67, 68],
                       "webp 的 review 行扫描不符（疑似行镜像）")
    }

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

    // MARK: - v2 看向扫描（行 9/10）

    func test_v2LookRowsScanToSixteenDirectionSlots() throws {
        // 行 9 全 8 格 + 行 10 前 4 格：方向 0…7 与 8…11 有帧，12…15 缺帧。
        let directory = try makePet(
            slug: "lookfull",
            framesByRow: [0: 2, 9: 8, 10: 4],
            atlasRows: 11
        )

        let asset = try PetdexAssetAdapter.load(from: directory)

        XCTAssertTrue(asset.hasLookFrames)
        // 帧号 = 行优先编号：方向 i 固定 9×8+i（不随占用重排）。
        let expected: [Int?] = (72...83).map { Optional($0) }   // 行 9 全部 + 行 10 前 4 格 → 方向 0…11
            + [nil, nil, nil, nil]                              // 行 10 后 4 格空 → 方向 12…15
        XCTAssertEqual(asset.lookFrames, expected)
        XCTAssertEqual(asset.lookFrame(direction: 0), 72)
        XCTAssertEqual(asset.lookFrame(direction: 8), 80)
        XCTAssertNil(asset.lookFrame(direction: 12), "空格保留槽位（缺帧回退底层）")
    }

    func test_v2LookRowsPartiallyOccupiedKeepSlots() throws {
        // 行 9 只有第 3/6 格占用（不连续）：方向 2 与 5 有帧，其余槽位为 nil。
        let directory = workDirectory.appendingPathComponent("look-sparse", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeAtlas(
            to: directory,
            // 帧 0 = 行 0 占位（九行状态行须至少一个动画）；74 / 77 = 行 9 的方向帧。
            occupiedCells: [0, 9 * 8 + 2, 9 * 8 + 5],
            rows: 11
        )
        try writeManifest(to: directory, slug: "look-sparse")

        let asset = try PetdexAssetAdapter.load(from: directory)

        XCTAssertEqual(asset.lookFrame(direction: 2), 74)
        XCTAssertEqual(asset.lookFrame(direction: 5), 77)
        XCTAssertNil(asset.lookFrame(direction: 0))
        XCTAssertNil(asset.lookFrame(direction: 3), "非连续占用的空位不重排")
    }

    func test_v2LookRowsAllEmptyDisablesLook() throws {
        let directory = try makePet(slug: "lookempty", framesByRow: [0: 2], atlasRows: 11)

        let asset = try PetdexAssetAdapter.load(from: directory)

        XCTAssertFalse(asset.hasLookFrames, "行 9/10 全空 → 看向整体不启用")
        XCTAssertEqual(asset.lookFrames, Array(repeating: nil, count: 16))
    }

    func test_v1AtlasHasNoLookCapability() throws {
        let directory = try makePet(slug: "v1pet", framesByRow: [0: 2], atlasRows: 9)

        let asset = try PetdexAssetAdapter.load(from: directory)

        XCTAssertFalse(asset.hasLookFrames, "v1（8×9）无行 9/10，无看向")
    }

    /// 直接写一张指定帧序号集合占用的图集（v2 look 非连续占用用）。
    private func writeAtlas(to directory: URL, occupiedCells: Set<Int>, rows: Int) throws {
        let columns = 8
        let cellWidth = 24, cellHeight = 26
        let width = columns * cellWidth
        let height = rows * cellHeight
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
            for cell in occupiedCells {
                let column = cell % columns
                let row = cell / columns
                // 逻辑行 0 = 文件顶部（高 y 区域）。
                let y = (rows - 1 - row) * cellHeight
                context.fill(CGRect(x: column * cellWidth, y: y, width: cellWidth, height: cellHeight))
            }
        }
        let image: CGImage? = buffer.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        let png = try XCTUnwrap(image.flatMap {
            NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:])
        })
        try png.write(to: directory.appendingPathComponent("spritesheet.png"))
    }

    private func writeManifest(to directory: URL, slug: String) throws {
        let manifest: [String: Any] = ["id": slug, "displayName": slug.capitalized]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("pet.json"))
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
