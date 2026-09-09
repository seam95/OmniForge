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

    func test_builtInAssetParsesAndCoversAllStates() throws {
        // 内置资产必须覆盖四个行为状态的动画。
        // 资源目录未声明进 SPM target，按源码树相对路径定位。
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()   // Pet
            .deletingLastPathComponent()   // Models
            .deletingLastPathComponent()   // OmniForgeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let assetURL = repositoryRoot
            .appendingPathComponent("Resources/Pets/cat", isDirectory: true)
        let asset = try PetSpriteAsset.load(from: assetURL)

        for animationID in [PetAnimationID.idle, PetAnimationID.walk, PetAnimationID.fall, PetAnimationID.petted] {
            XCTAssertNotNil(asset.animation(id: animationID), "缺少动画：\(animationID)")
        }
        XCTAssertEqual(asset.grid.columns, 8)
        XCTAssertEqual(asset.grid.rows, 9)
    }
}
