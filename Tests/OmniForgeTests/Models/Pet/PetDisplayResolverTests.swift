import XCTest
@testable import OmniForge

/// 最终显示解析测试：优先级顺序（拖动/投掷 → 看向 → 悬停 → 底层）、
/// 缺帧回退、镜像标记与一次性时间轴。
final class PetDisplayResolverTests: XCTestCase {
    /// 构造测试资产：idle/walk 四帧循环、drag 两帧、walkLeft/walkRight/look 可选注入。
    private func makeAsset(
        walkLeft: Bool = false,
        walkRight: Bool = false,
        includeDrag: Bool = true,
        includeFall: Bool = false,
        lookFrames: [Int?]? = nil
    ) -> PetSpriteAsset {
        var animations = [
            PetSpriteAsset.Animation(id: PetAnimationID.idle, frames: [0, 1, 2, 3], fps: 4, loops: true, mirrorX: false),
            PetSpriteAsset.Animation(id: PetAnimationID.walk, frames: [8, 9, 10, 11], fps: 8, loops: true, mirrorX: true),
        ]
        if includeDrag {
            animations.append(
                PetSpriteAsset.Animation(id: PetAnimationID.drag, frames: [32, 33], fps: 8, loops: true, mirrorX: false)
            )
        }
        if includeFall {
            animations.append(
                PetSpriteAsset.Animation(id: PetAnimationID.fall, frames: [16], fps: 1, loops: true, mirrorX: false)
            )
        }
        if walkLeft {
            animations.append(
                PetSpriteAsset.Animation(id: PetAnimationID.walkLeft, frames: [16, 17], fps: 8, loops: true, mirrorX: false)
            )
        }
        if walkRight {
            animations.append(
                PetSpriteAsset.Animation(id: PetAnimationID.walkRight, frames: [24, 25], fps: 8, loops: true, mirrorX: false)
            )
        }
        var asset = PetSpriteAsset(
            id: "resolver-pet",
            displayName: "Resolver Pet",
            atlasFileName: "atlas.png",
            grid: PetSpriteAsset.Grid(columns: 8, rows: 9, cellWidth: 32, cellHeight: 32),
            animations: animations
        )
        if let lookFrames {
            asset.lookFrames = lookFrames
        }
        return asset
    }

    private let now = Date(timeIntervalSinceReferenceDate: 100)
    private let stateEnteredAt = Date(timeIntervalSinceReferenceDate: 90)

    // MARK: - 底层动画

    func test_idleResolvesBaseAnimationFrames() {
        let asset = makeAsset()
        // idle 4 帧 @4fps，循环相位按挂钟取模：100-90=10s → 10 % 1.0 = 0 → 帧 0。
        let resolution = PetDisplayResolver.resolve(
            state: .idle, asset: asset, dragFacing: nil, lookDirection: nil, hover: nil,
            now: now, stateEnteredAt: stateEnteredAt
        )
        XCTAssertEqual(resolution?.frameIndex, 0)
        XCTAssertEqual(resolution?.mirrored, false)
    }

    func test_walkLeftMirrorsSingleFacingAsset() {
        let asset = makeAsset()
        let resolution = PetDisplayResolver.resolve(
            state: .walk(direction: .left), asset: asset, dragFacing: nil, lookDirection: nil, hover: nil,
            now: now, stateEnteredAt: stateEnteredAt
        )
        // 单朝向 walk + mirrorX：向左行走必须镜像。
        XCTAssertEqual(resolution?.animation.id, PetAnimationID.walk)
        XCTAssertEqual(resolution?.mirrored, true)
    }

    func test_walkPrefersDirectionalAnimations() {
        let asset = makeAsset(walkLeft: true, walkRight: true)
        let left = PetDisplayResolver.resolve(
            state: .walk(direction: .left), asset: asset, dragFacing: nil, lookDirection: nil, hover: nil,
            now: now, stateEnteredAt: stateEnteredAt
        )
        let right = PetDisplayResolver.resolve(
            state: .walk(direction: .right), asset: asset, dragFacing: nil, lookDirection: nil, hover: nil,
            now: now, stateEnteredAt: stateEnteredAt
        )
        XCTAssertEqual(left?.animation.id, PetAnimationID.walkLeft)
        XCTAssertEqual(right?.animation.id, PetAnimationID.walkRight)
        XCTAssertEqual(left?.mirrored, false)
    }

    // MARK: - 看向覆盖

    func test_lookDirectionOverridesBaseAnimationWhenFrameExists() {
        // 槽位 4（右）有帧 72；即便底层在播 idle 也显示看向单帧。
        let asset = makeAsset(lookFrames: Array(repeating: nil, count: 16).with(4, 72))
        let resolution = PetDisplayResolver.resolve(
            state: .idle, asset: asset, dragFacing: nil, lookDirection: 4, hover: nil,
            now: now, stateEnteredAt: stateEnteredAt
        )
        XCTAssertEqual(resolution?.frameIndex, 72)
        XCTAssertEqual(resolution?.mirrored, false)
    }

    func test_lookDirectionMissingFrameFallsBackToBaseAnimation() {
        // 槽位 4 无帧：回退底层动画（不挪用相邻方向）。
        let asset = makeAsset(lookFrames: Array(repeating: nil, count: 16).with(8, 64))
        let resolution = PetDisplayResolver.resolve(
            state: .idle, asset: asset, dragFacing: nil, lookDirection: 4, hover: nil,
            now: now, stateEnteredAt: stateEnteredAt
        )
        XCTAssertEqual(resolution?.animation.id, PetAnimationID.idle)
        XCTAssertEqual(resolution?.frameIndex, 0)
    }

    func test_lookDirectionInsideReactionStateStillOverrides() {
        // 渲染顺序：看向优先于一切底层行为动画（含反应态）。
        let asset = makeAsset(lookFrames: Array(repeating: nil, count: 16).with(0, 72))
        let resolution = PetDisplayResolver.resolve(
            state: .reaction(kind: .heat, resumeState: .idle), asset: asset,
            dragFacing: nil, lookDirection: 0, hover: nil,
            now: now, stateEnteredAt: stateEnteredAt
        )
        XCTAssertEqual(resolution?.frameIndex, 72)
    }

    // MARK: - 悬停覆盖

    func test_hoverOverridesBaseAnimationWithIndependentTimeline() {
        let asset = makeAsset()
        let hover = PetHoverPlayback(
            animation: asset.animation(id: PetAnimationID.drag)!.oneShot(),
            startedAt: now.addingTimeInterval(-0.125)  // drag 2 帧 @8fps（每帧 0.125s）
        )
        // 独立时间轴：从 hover.startedAt 起播 0.125s → 第 2 帧（末帧定格）。
        let resolution = PetDisplayResolver.resolve(
            state: .idle, asset: asset, dragFacing: nil, lookDirection: nil, hover: hover,
            now: now, stateEnteredAt: stateEnteredAt
        )
        XCTAssertEqual(resolution?.animation.id, PetAnimationID.drag)
        XCTAssertEqual(resolution?.frameIndex, 33)
    }

    func test_hoverFinishedPlaybackIsRemovedByManagerNotResolver() {
        // 播放完的移除由 Manager（updateDisplaySnapshot）负责；Resolver 对传入即播放。
        let animation = makeAsset().animation(id: PetAnimationID.drag)!.oneShot()
        let hover = PetHoverPlayback(animation: animation, startedAt: now.addingTimeInterval(-10))
        XCTAssertTrue(hover.isFinished(at: now), "远超总时长的播放应判定结束")
        XCTAssertFalse(
            PetHoverPlayback(animation: animation, startedAt: now).isFinished(at: now),
            "刚触发的播放未结束"
        )
    }

    func test_hoverDoesNotResetBaseStateTimeline() {
        // 悬停期间底层时间轴照常推进：悬停结束后（hover=nil）idle 相位按全局挂钟继续。
        let asset = makeAsset()
        let resolution = PetDisplayResolver.resolve(
            state: .idle, asset: asset, dragFacing: nil, lookDirection: nil, hover: nil,
            now: now, stateEnteredAt: stateEnteredAt
        )
        XCTAssertEqual(resolution?.frameIndex, 0, "10s 挂钟相位 10 % 1.0 = 0（挂钟取模，与悬停无关）")
    }

    // MARK: - 拖动优先级

    func test_dragSuspendsLookAndHover() {
        // 拖动/投掷最高优先：即使采样层给出看向方向，也显示拖动表现。
        let asset = makeAsset(lookFrames: Array(repeating: nil, count: 16).with(4, 72))
        let hover = PetHoverPlayback(
            animation: asset.animation(id: PetAnimationID.drag)!.oneShot(),
            startedAt: now
        )
        let resolution = PetDisplayResolver.resolve(
            state: .drag, asset: asset, dragFacing: nil, lookDirection: 4, hover: hover,
            now: now, stateEnteredAt: stateEnteredAt
        )
        XCTAssertEqual(resolution?.animation.id, PetAnimationID.drag, "悬空姿态优先于看向与悬停")
    }

    func test_dragWithFacingShowsDirectionalWalking() {
        let asset = makeAsset(walkLeft: true, walkRight: true)
        let right = PetDisplayResolver.resolve(
            state: .drag, asset: asset, dragFacing: .right, lookDirection: nil, hover: nil,
            now: now, stateEnteredAt: stateEnteredAt
        )
        let left = PetDisplayResolver.resolve(
            state: .drag, asset: asset, dragFacing: .left, lookDirection: nil, hover: nil,
            now: now, stateEnteredAt: stateEnteredAt
        )
        XCTAssertEqual(right?.animation.id, PetAnimationID.walkRight, "拖动向右显示右行走")
        XCTAssertEqual(left?.animation.id, PetAnimationID.walkLeft, "拖动向左显示左行走")
    }

    func test_dragWithFacingMirrorsSingleFacingWalk() {
        let asset = makeAsset()  // 只有单朝向 walk + mirrorX
        let left = PetDisplayResolver.resolve(
            state: .drag, asset: asset, dragFacing: .left, lookDirection: nil, hover: nil,
            now: now, stateEnteredAt: stateEnteredAt
        )
        XCTAssertEqual(left?.animation.id, PetAnimationID.walk)
        XCTAssertEqual(left?.mirrored, true, "缺分向素材走 walk + mirrorX 降级")
    }

    func test_dragWithoutDragAssetFallsBackToFallThenPlaceholder() {
        // drag 缺失但 fall 在：拖动显示回退 fall。
        let withFall = makeAsset(includeDrag: false, includeFall: true)
        let toFall = PetDisplayResolver.resolve(
            state: .drag, asset: withFall, dragFacing: nil, lookDirection: nil, hover: nil,
            now: now, stateEnteredAt: stateEnteredAt
        )
        XCTAssertEqual(toFall?.animation.id, PetAnimationID.fall, "drag 缺失时回退 fall")

        // drag 与 fall 均缺失 → nil（占位）。
        let bare = makeAsset(includeDrag: false)
        let none = PetDisplayResolver.resolve(
            state: .drag, asset: bare, dragFacing: nil, lookDirection: nil, hover: nil,
            now: now, stateEnteredAt: stateEnteredAt
        )
        XCTAssertNil(none, "drag 与 fall 均缺失时应显示占位")
    }
}

// MARK: - 测试辅助

private extension Array {
    /// 返回副本，将指定下标置为给定值（构造 16 槽位局部占用用）。
    func with(_ index: Int, _ value: Element) -> [Element] {
        var copy = self
        guard index >= 0, index < count else { return copy }
        copy[index] = value
        return copy
    }
}
