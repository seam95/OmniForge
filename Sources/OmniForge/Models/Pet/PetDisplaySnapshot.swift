import CoreGraphics
import Foundation

/// 最终显示快照：渲染与命中层共享的唯一帧真相（同一资产、帧号、镜像与尺寸）。
/// 由 Manager 的显示时钟推进计算；SwiftUI 视图只读取呈现，不做二次推导。
struct PetDisplaySnapshot: Equatable {
    /// 当前宠物资产（含图集定位与网格，命中层据此共享同一裁剪结果）。
    let asset: PetSpriteAsset
    /// 最终显示帧号（图集单元格序号）。
    let frameIndex: Int
    /// 是否水平镜像。
    let mirrored: Bool
    /// 显示尺寸（点）。
    let size: CGSize
}

/// 悬停覆盖的一次性播放参数（独立时间轴，不触碰底层行为态）。
struct PetHoverPlayback: Equatable {
    /// 播放的动画（以 `oneShot()` 构造的非循环副本，不修改共享动画声明）。
    let animation: PetSpriteAsset.Animation
    /// 播放起始时刻（Manager 显示时钟域）。
    let startedAt: Date

    /// 是否已播完（elapsed ≥ 动画总时长即结束，由 Manager 在每 tick 检查并移除覆盖）。
    func isFinished(at now: Date) -> Bool {
        let total = animation.frameDuration * Double(animation.frames.count)
        return now.timeIntervalSince(startedAt) >= total
    }
}

extension PetSpriteAsset {
    /// 悬空姿态动画（拖动 / 投掷 / 悬停 / hop 共用的降级链：drag → fall）。
    func suspendedAnimation() -> Animation? {
        animation(id: PetAnimationID.drag) ?? animation(id: PetAnimationID.fall)
    }
}

extension PetSpriteAsset.Animation {
    /// 以本动画参数构造一次性播放副本（悬停覆盖用）。
    func oneShot() -> PetSpriteAsset.Animation {
        PetSpriteAsset.Animation(id: id, frames: frames, fps: fps, loops: false, mirrorX: mirrorX)
    }
}

/// 最终显示解析（纯函数）：按「直接拖动/投掷 → 看向 → 悬停 → 底层行为动画」的固定顺序
/// 选出当前帧。输入全部为值，便于单测覆盖优先级与回退语义。
enum PetDisplayResolver {
    /// 解析结果：动画（或单帧）+ 帧序号 + 镜像标记。
    struct Resolution: Equatable {
        let animation: PetSpriteAsset.Animation
        let frameIndex: Int
        let mirrored: Bool
    }

    /// - Parameters:
    ///   - state: 底层行为态（拖动/投掷期间为 `.drag`）。
    ///   - dragFacing: 直接拖动期间的手势水平朝向（阶段②驱动分向走动表现；nil = 非拖动）。
    ///   - lookDirection: 看向方向槽位（指针在矩形外且非拖动/投掷时由采样提供）。
    ///   - hover: 悬停一次性播放（nil = 无覆盖）。
    ///   - now: Manager 显示时钟（虚拟挂钟，驱动循环相位与一次性时间轴）。
    ///   - stateEnteredAt: 当前底层行为态的进入时刻（显示时钟域）。
    static func resolve(
        state: PetBehaviorState,
        asset: PetSpriteAsset,
        dragFacing: PetDirection?,
        lookDirection: Int?,
        hover: PetHoverPlayback?,
        now: Date,
        stateEnteredAt: Date
    ) -> Resolution? {
        // 1) 直接拖动 / 投掷：有手势朝向且素材有分向行走时显示对应走动；否则悬空姿态。
        if case .drag = state {
            if let facing = dragFacing,
               let walking = dragWalkingAnimation(asset: asset, facing: facing) {
                let index = PetFrameSequencer.frameIndex(
                    now: now, stateEnteredAt: stateEnteredAt, animation: walking.animation
                )
                if let index {
                    return Resolution(animation: walking.animation, frameIndex: index, mirrored: walking.mirrored)
                }
            }
            guard let suspended = asset.suspendedAnimation() else { return nil }
            let index = PetFrameSequencer.frameIndex(
                now: now, stateEnteredAt: stateEnteredAt, animation: suspended
            )
            return index.map { Resolution(animation: suspended, frameIndex: $0, mirrored: false) }
        }

        // 2) 看向覆盖：方向槽位有帧则定格单帧（缺帧直接落到下一层，不挪用相邻方向）。
        if let lookDirection, let frame = asset.lookFrame(direction: lookDirection) {
            guard let animation = asset.animation(id: PetAnimationID.idle)
                ?? asset.animations.first else { return nil }
            return Resolution(animation: animation, frameIndex: frame, mirrored: false)
        }

        // 3) 悬停覆盖：独立一次性时间轴（素材链 drag → fall 已在触发时定稿）。
        if let hover {
            let index = PetFrameSequencer.frameIndex(
                now: now, stateEnteredAt: hover.startedAt, animation: hover.animation
            )
            return index.map { Resolution(animation: hover.animation, frameIndex: $0, mirrored: false) }
        }

        // 4) 底层行为动画。
        guard let base = baseAnimation(state: state, asset: asset) else { return nil }
        let index = PetFrameSequencer.frameIndex(
            now: now, stateEnteredAt: stateEnteredAt, animation: base.animation
        )
        return index.map { Resolution(animation: base.animation, frameIndex: $0, mirrored: base.mirrored) }
    }

    // MARK: - 底层动画选择（与旧视图层 resolveAnimation 同口径）

    /// 依据行为状态选择底层动画：优先分向素材，单朝向 `walk` + 镜像兜底。
    private static func baseAnimation(
        state: PetBehaviorState,
        asset: PetSpriteAsset
    ) -> (animation: PetSpriteAsset.Animation, mirrored: Bool)? {
        switch state {
        case .idle:
            return asset.animation(id: PetAnimationID.idle).map { ($0, false) }
                ?? asset.animations.first.map { ($0, false) }

        case .walk(let direction):
            if direction == .right, let animation = asset.animation(id: PetAnimationID.walkRight) {
                return (animation, false)
            }
            if direction == .left, let animation = asset.animation(id: PetAnimationID.walkLeft) {
                return (animation, false)
            }
            if let animation = asset.animation(id: PetAnimationID.walk) {
                return (animation, direction == .left && animation.mirrorX)
            }
            return asset.animations.first.map { ($0, direction == .left) }

        case .drag:
            return asset.suspendedAnimation().map { ($0, false) }

        case .petted:
            return asset.animation(id: PetAnimationID.petted).map { ($0, false) }

        case .reaction(let kind, _):
            // 降级链：专用动画 → 抚摸 → 空闲（内置宠物缺专用素材时逐级回退）。
            for id in kind.animationFallbacks {
                if let animation = asset.animation(id: id) {
                    return (animation, false)
                }
            }
            return nil

        case .frolic:
            // 玩耍复用挥手（抚摸）素材。
            return asset.animation(id: PetAnimationID.petted).map { ($0, false) }

        case .hop:
            // 蹦跳复用悬空素材（drag → fall 降级链）。
            return asset.suspendedAnimation().map { ($0, false) }
        }
    }

    /// 拖动期间的分向走动表现：分向素材优先，单朝向 walk + 镜像兜底。
    private static func dragWalkingAnimation(
        asset: PetSpriteAsset,
        facing: PetDirection
    ) -> (animation: PetSpriteAsset.Animation, mirrored: Bool)? {
        if facing == .right, let animation = asset.animation(id: PetAnimationID.walkRight) {
            return (animation, false)
        }
        if facing == .left, let animation = asset.animation(id: PetAnimationID.walkLeft) {
            return (animation, false)
        }
        if let animation = asset.animation(id: PetAnimationID.walk) {
            return (animation, facing == .left && animation.mirrorX)
        }
        return nil
    }
}
