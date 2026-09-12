import XCTest
@testable import OmniForge

/// 宠物资产 `pet.json` 解析测试：帧区间、网格校验、越界报错。
final class PetSpriteAssetTests: XCTestCase {
    private func makeJSON(
        grid: String = #"{ "columns": 8, "rows": 9, "cellSize": [32, 32] }"#,
        animations: String = #"[{ "id": "idle", "frames": "0-3", "fps": 4, "loop": true }]"#
    ) -> Data {
        """
        {
          "id": "cat",
          "name": "cat",
          "displayName": "像素猫",
          "atlas": "cat_atlas.png",
          "grid": \(grid),
          "animations": \(animations)
        }
        """.data(using: .utf8)!
    }

    func test_decodeParsesGridAndAnimation() throws {
        let asset = try PetSpriteAsset.decode(from: makeJSON())

        XCTAssertEqual(asset.id, "cat")
        XCTAssertEqual(asset.displayName, "像素猫")
        XCTAssertEqual(asset.atlasFileName, "cat_atlas.png")
        XCTAssertEqual(asset.grid.columns, 8)
        XCTAssertEqual(asset.grid.rows, 9)
        XCTAssertEqual(asset.grid.cellWidth, 32)
        XCTAssertEqual(asset.grid.cellHeight, 32)
        XCTAssertEqual(asset.grid.cellCount, 72)
        XCTAssertEqual(asset.animations.count, 1)
        XCTAssertEqual(asset.animations[0].frames, [0, 1, 2, 3])
        XCTAssertEqual(asset.animations[0].fps, 4)
        XCTAssertTrue(asset.animations[0].loops)
    }

    func test_decodeParsesCommaSeparatedRanges() throws {
        let json = makeJSON(animations: #"[{ "id": "walk", "frames": "8-9,11", "fps": 8 }]"#)
        let asset = try PetSpriteAsset.decode(from: json)

        XCTAssertEqual(asset.animations[0].frames, [8, 9, 11])
        // 未声明 loop 时默认循环。
        XCTAssertTrue(asset.animations[0].loops)
        XCTAssertFalse(asset.animations[0].mirrorX)
    }

    func test_decodeSingleFrame() throws {
        let json = makeJSON(animations: #"[{ "id": "fall", "frames": "16", "fps": 1 }]"#)
        let asset = try PetSpriteAsset.decode(from: json)

        XCTAssertEqual(asset.animations[0].frames, [16])
    }

    func test_decodeHonoursMirrorX() throws {
        let json = makeJSON(
            animations: #"[{ "id": "walk", "frames": "8-11", "mirrorX": true }]"#
        )
        let asset = try PetSpriteAsset.decode(from: json)

        XCTAssertTrue(asset.animations[0].mirrorX)
    }

    func test_animationLookupById() throws {
        let json = makeJSON(animations: """
        [
          { "id": "idle", "frames": "0-3" },
          { "id": "walk", "frames": "8-11" }
        ]
        """)
        let asset = try PetSpriteAsset.decode(from: json)

        XCTAssertEqual(asset.animation(id: "walk")?.frames, [8, 9, 10, 11])
        XCTAssertNil(asset.animation(id: "missing"))
    }

    func test_frameDurationDerivesFromFPS() throws {
        let asset = try PetSpriteAsset.decode(from: makeJSON())

        XCTAssertEqual(asset.animations[0].frameDuration, 0.25, accuracy: 0.0001)
    }

    func test_decodeRejectsInvalidFrameRange() {
        let json = makeJSON(animations: #"[{ "id": "bad", "frames": "3-1" }]"#)

        XCTAssertThrowsError(try PetSpriteAsset.decode(from: json)) { error in
            XCTAssertEqual(
                error as? PetAssetError,
                .invalidFrameRange(animation: "bad", raw: "3-1")
            )
        }
    }

    func test_decodeRejectsFrameOutOfBounds() {
        // 网格 8×9 = 72 格，帧 99 越界。
        let json = makeJSON(animations: #"[{ "id": "bad", "frames": "99" }]"#)

        XCTAssertThrowsError(try PetSpriteAsset.decode(from: json)) { error in
            XCTAssertEqual(
                error as? PetAssetError,
                .frameOutOfBounds(animation: "bad", index: 99, cellCount: 72)
            )
        }
    }

    func test_decodeRejectsEmptyAnimations() {
        let json = makeJSON(animations: "[]")

        XCTAssertThrowsError(try PetSpriteAsset.decode(from: json)) { error in
            XCTAssertEqual(error as? PetAssetError, .emptyAnimations)
        }
    }

    func test_decodeRejectsEmptyFrames() {
        let json = makeJSON(animations: #"[{ "id": "empty", "frames": "" }]"#)

        XCTAssertThrowsError(try PetSpriteAsset.decode(from: json)) { error in
            XCTAssertEqual(error as? PetAssetError, .emptyFrames(animation: "empty"))
        }
    }

    func test_decodeRejectsMalformedJSON() {
        let data = "{ not json".data(using: .utf8)!

        XCTAssertThrowsError(try PetSpriteAsset.decode(from: data)) { error in
            guard case .invalidJSON = error as? PetAssetError else {
                return XCTFail("期望 invalidJSON，实际 \(error)")
            }
        }
    }

    func test_builtInAssetParsesViaPetdexAdapterChain() throws {
        // 内置资产（doraemon）为 petdex 格式（极简 pet.json + 图集行号约定），
        // 须走实际适配链（PetAssetLocator.load：自有格式失败 → petdex 兜底）验证，
        // 不能只以目录存在作为通过依据。
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()   // Pet
            .deletingLastPathComponent()   // Models
            .deletingLastPathComponent()   // OmniForgeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let assetURL = repositoryRoot
            .appendingPathComponent("Resources/Pets/\(PetAssetLocator.builtInPetID)", isDirectory: true)
        let asset = try PetAssetLocator.load(from: assetURL)

        XCTAssertEqual(asset.id, PetAssetLocator.builtInPetID)
        // 九行既有行为链：idle / 左右行 / 抚摸 / 悬空在 v1 图集上均应可用。
        for animationID in [
            PetAnimationID.idle, PetAnimationID.walkRight, PetAnimationID.walkLeft,
            PetAnimationID.petted, PetAnimationID.drag,
        ] {
            XCTAssertNotNil(asset.animation(id: animationID), "缺少动画：\(animationID)")
        }
        XCTAssertEqual(asset.grid.columns, 8)
    }

    // MARK: - look 动画（自有格式 16 向声明）

    func test_decodeParsesLookAnimationToSixteenSlots() throws {
        // 16 项帧号按方向顺序解释，不限于第 9/10 行。
        let json = makeJSON(
            animations: #"[{ "id": "idle", "frames": "0-3" }, { "id": "look", "frames": "0-15" }]"#
        )
        let asset = try PetSpriteAsset.decode(from: json)

        XCTAssertEqual(asset.lookFrames, (0..<16).map { Optional($0) })
        XCTAssertTrue(asset.hasLookFrames)
        XCTAssertNil(asset.animation(id: PetAnimationID.look), "look 不进普通动画表（不参与兜底）")
    }

    func test_decodeLookWithDuplicateFramesIsAllowed() throws {
        // 允许重复有效帧号（多个方向共用一帧）。
        let json = makeJSON(
            animations: #"[{ "id": "idle", "frames": "0-3" }, { "id": "look", "frames": "5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5" }]"#
        )
        let asset = try PetSpriteAsset.decode(from: json)

        XCTAssertEqual(asset.lookFrame(direction: 0), 5)
        XCTAssertEqual(asset.lookFrame(direction: 15), 5)
    }

    func test_decodeLookWithWrongCountIsIgnored() throws {
        // 数量 ≠ 16：忽略整组 look 能力，保留其他有效动画。
        let json = makeJSON(
            animations: #"[{ "id": "idle", "frames": "0-3" }, { "id": "look", "frames": "0-7" }]"#
        )
        let asset = try PetSpriteAsset.decode(from: json)

        XCTAssertFalse(asset.hasLookFrames)
        XCTAssertEqual(asset.lookFrames, Array(repeating: nil, count: 16))
        XCTAssertNotNil(asset.animation(id: PetAnimationID.idle), "非法 look 不影响其他动画加载")
    }

    func test_decodeLookWithOutOfBoundsFrameIsIgnored() throws {
        // 帧号越界（72 格图集帧 80）：忽略整组 look。
        let json = makeJSON(
            grid: #"{ "columns": 8, "rows": 9, "cellSize": [32, 32] }"#,
            animations: #"""
            [{ "id": "idle", "frames": "0-3" }, { "id": "look", "frames": "0-7,8-15,16-23,24-31,32-39,40-47,48-55,56-63,64-71,72-79" }]
            """#
        )
        let asset = try PetSpriteAsset.decode(from: json)

        XCTAssertFalse(asset.hasLookFrames, "含越界帧的 look 声明整体忽略")
    }
}
