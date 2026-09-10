import AppKit
import SwiftUI

/// 桌宠窗口内视图：按行为状态播放图集帧动画，承载单击抚摸与拖拽。
@MainActor
struct PetSpriteView: View {
    @ObservedObject var manager: DesktopPetManager
    /// 宠物资产（nil 时显示占位色块，便于资产缺失时仍可调试窗口行为）。
    var asset: PetSpriteAsset?

    /// 当前动画累计时间，用于推导非循环动画的帧序号。
    @State private var elapsed: TimeInterval = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            sprite(at: context.date)
        }
        .frame(width: manager.petSize.width, height: manager.petSize.height)
        .contentShape(Rectangle())
        .onTapGesture { manager.pet() }
        .gesture(dragGesture)
        .contextMenu { contextMenuItems }
        .onChange(of: manager.behaviorState) { _, _ in
            // 状态切换时重置动画时间轴，避免沿用上一段动画的帧进度。
            elapsed = 0
        }
    }

    /// 右键菜单三项：重置位置 / 隐藏宠物 / 打开设置。
    @ViewBuilder
    private var contextMenuItems: some View {
        let strings = manager.strings
        Button(strings.desktopPetResetPosition) { manager.resetPosition() }
        Button(strings.desktopPetHide) { manager.requestHide() }
        Button(strings.desktopPetOpenSettings) { manager.requestOpenSettings() }
    }

    // MARK: - 帧渲染

    @ViewBuilder
    private func sprite(at date: Date) -> some View {
        if let asset, let resolved = resolveAnimation(asset: asset),
           let frameIndex = frameIndex(at: date, animation: resolved.animation),
           let image = SpriteAtlasImageProvider.shared.image(asset: asset, frameIndex: frameIndex) {
            Image(nsImage: image)
                .interpolation(.none)  // 像素最近邻采样，Retina 下保持锐利
                .resizable()
                .frame(width: manager.petSize.width, height: manager.petSize.height)
                // 单朝向行走素材在向左行走时水平镜像。
                .scaleEffect(x: resolved.mirrored ? -1 : 1, y: 1)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.accentColor.opacity(0.25))
            .overlay(
                Image(systemName: "pawprint.fill")
                    .foregroundStyle(.secondary)
            )
    }

    /// 依据当前状态选择动画。
    /// 优先用左右分行的素材（社区资产），否则用单朝向 `walk` + 镜像（内置资产）。
    private func resolveAnimation(
        asset: PetSpriteAsset
    ) -> (animation: PetSpriteAsset.Animation, mirrored: Bool)? {
        switch manager.behaviorState {
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
            let animation = asset.animation(id: PetAnimationID.drag)
                ?? asset.animation(id: PetAnimationID.fall)
            return animation.map { ($0, false) }

        case .petted:
            return asset.animation(id: PetAnimationID.petted).map { ($0, false) }

        case .reaction(let kind, _):
            // 降级链：专用动画 → 抚摸 → 空闲（内置猫缺专用素材时逐级回退）。
            for id in kind.animationFallbacks {
                if let animation = asset.animation(id: id) {
                    return (animation, false)
                }
            }
            return nil
        }
    }

    /// 依据已播时间推导图集帧序号。
    private func frameIndex(at date: Date, animation: PetSpriteAsset.Animation) -> Int? {
        guard !animation.frames.isEmpty else { return nil }
        let frameCount = animation.frames.count
        let total = animation.frameDuration * Double(frameCount)
        let phase: TimeInterval
        if animation.loops {
            phase = total > 0
                ? date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: total)
                : 0
        } else {
            // 一次性动画：播完停在最后一帧。
            phase = min(elapsed, total)
        }
        let index = animation.frameDuration > 0 ? Int(phase / animation.frameDuration) : 0
        return animation.frames[min(index, frameCount - 1)]
    }

    // MARK: - 拖拽

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { _ in
                if case .drag = manager.behaviorState { return }
                manager.beginDrag()
            }
            .onEnded { _ in
                manager.endDrag()
            }
    }
}

/// 图集切片缓存：按资产与帧序号缓存切好的 NSImage，避免每帧重切。
@MainActor
final class SpriteAtlasImageProvider {
    static let shared = SpriteAtlasImageProvider()

    private var atlasCache: [String: NSImage] = [:]
    private var frameCache: [String: NSImage] = [:]

    private init() {}

    /// 取指定帧的切图；图集缺失时返回 nil（调用方回退占位）。
    func image(asset: PetSpriteAsset, frameIndex: Int) -> NSImage? {
        let frameKey = "\(asset.id)#\(frameIndex)"
        if let cached = frameCache[frameKey] { return cached }
        guard let atlas = atlas(for: asset) else { return nil }
        guard let cropped = crop(atlas: atlas, asset: asset, frameIndex: frameIndex) else {
            return nil
        }
        frameCache[frameKey] = cropped
        return cropped
    }

    /// 清空缓存（资产热更新或测试用）。
    func clearCache() {
        atlasCache.removeAll()
        frameCache.removeAll()
    }

    private func atlas(for asset: PetSpriteAsset) -> NSImage? {
        if let cached = atlasCache[asset.id] { return cached }
        guard let url = PetAssetLocator.atlasURL(asset: asset),
              let image = NSImage(contentsOf: url) else { return nil }
        atlasCache[asset.id] = image
        return image
    }

    /// 从图集裁出单元格。坐标为左上原点（图集坐标系），需转成 NSImage 的下原点。
    private func crop(atlas: NSImage, asset: PetSpriteAsset, frameIndex: Int) -> NSImage? {
        let grid = asset.grid
        guard frameIndex >= 0, frameIndex < grid.cellCount else { return nil }
        let column = frameIndex % grid.columns
        let row = frameIndex / grid.columns
        let cellSize = NSSize(width: grid.cellWidth, height: grid.cellHeight)
        let atlasSize = atlas.size
        guard atlasSize.width > 0, atlasSize.height > 0 else { return nil }

        // 图集可能被系统按点尺寸缩放，按比例换算实际像素坐标。
        let scaleX = atlasSize.width / CGFloat(grid.columns * grid.cellWidth)
        let scaleY = atlasSize.height / CGFloat(grid.rows * grid.cellHeight)
        let pixelOrigin = CGPoint(
            x: CGFloat(column) * CGFloat(grid.cellWidth) * scaleX,
            y: atlasSize.height - CGFloat(row + 1) * CGFloat(grid.cellHeight) * scaleY
        )
        let rect = NSRect(
            x: pixelOrigin.x,
            y: pixelOrigin.y,
            width: cellSize.width * scaleX,
            height: cellSize.height * scaleY
        )

        let cropped = NSImage(size: cellSize)
        cropped.lockFocus()
        atlas.draw(
            in: NSRect(origin: .zero, size: cellSize),
            from: rect,
            operation: .copy,
            fraction: 1.0
        )
        cropped.unlockFocus()
        cropped.capInsets = NSEdgeInsets()
        return cropped
    }
}
