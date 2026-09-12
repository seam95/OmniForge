import AppKit
import SwiftUI

/// 桌宠窗口内视图：按行为状态播放图集帧动画，承载单击抚摸与拖拽。
@MainActor
struct PetSpriteView: View {
    @ObservedObject var manager: DesktopPetManager
    /// 宠物资产（nil 时显示占位色块，便于资产缺失时仍可调试窗口行为）。
    var asset: PetSpriteAsset?

    /// 当前行为状态的进入时刻，作为一次性动画（抚摸 / 反应）的时间轴原点。
    @State private var stateEnteredAt = Date()

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
            stateEnteredAt = Date()
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
        // 固定双层结构：占位只在资产缺失时出现（调试窗口行为用）；
        // 有资产时绝不渲染底色——像素图集帧有大量透明像素，
        // 常驻底色会把宠物周围整块染色（蓝色占位曾透出为背景色块）。
        ZStack {
            if asset == nil { placeholder }
            if let asset, let resolved = resolveAnimation(asset: asset),
               let frameIndex = PetFrameSequencer.frameIndex(
                   now: date,
                   stateEnteredAt: stateEnteredAt,
                   animation: resolved.animation
               ),
               let image = SpriteAtlasImageProvider.shared.image(asset: asset, frameIndex: frameIndex) {
                Image(nsImage: image)
                    .interpolation(.none)  // 像素最近邻采样，Retina 下保持锐利
                    .resizable()
                    .frame(width: manager.petSize.width, height: manager.petSize.height)
                    // 单朝向行走素材在向左行走时水平镜像。
                    .scaleEffect(x: resolved.mirrored ? -1 : 1, y: 1)
            }
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

        case .frolic:
            // 玩耍复用挥手（抚摸）素材。
            return asset.animation(id: PetAnimationID.petted).map { ($0, false) }

        case .hop:
            // 蹦跳复用悬空素材（jumping 行优先，其次 fall）。
            let animation = asset.animation(id: PetAnimationID.drag)
                ?? asset.animation(id: PetAnimationID.fall)
            return animation.map { ($0, false) }
        }
    }

    // MARK: - 拖拽

    private var dragGesture: some Gesture {
        // 阈值 8pt：触摸板单击的轻微位移（常见 3-5pt）不再误入拖动态
        // （误入会闪一帧悬空姿态再跳回，观感为抚摸时闪烁）。
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if case .drag = manager.behaviorState {
                    manager.dragWindow(by: value.translation)
                    return
                }
                manager.beginDrag()
                manager.dragWindow(by: value.translation)
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

    private var atlasBufferCache: [String: [UInt8]] = [:]
    private var frameCache: [String: NSImage] = [:]

    private init() {}

    /// 取指定帧的切图；图集缺失时返回 nil（调用方回退占位）。
    func image(asset: PetSpriteAsset, frameIndex: Int) -> NSImage? {
        let frameKey = "\(asset.id)#\(frameIndex)"
        if let cached = frameCache[frameKey] { return cached }
        guard let cropped = crop(asset: asset, frameIndex: frameIndex) else {
            return nil
        }
        frameCache[frameKey] = cropped
        return cropped
    }

    /// 清空缓存（资产热更新或测试用）。
    func clearCache() {
        atlasImageCache.removeAll()
        frameCache.removeAll()
    }

    /// 图集 CGImage：按资产缓存，避免逐帧重复解码。
    private func atlasImage(asset: PetSpriteAsset) -> CGImage? {
        if let cached = atlasImageCache[asset.id] { return cached }
        guard let url = PetAssetLocator.atlasURL(asset: asset),
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        atlasImageCache[asset.id] = cgImage
        return cgImage
    }

    /// 从图集裁出单元格。
    ///
    /// 用 `CGImage.cropping` 直取像素：行 0 = 图集文件顶部，该语义对 PNG 与 webp
    /// 一致（与 `PetdexAssetAdapter` 的占用扫描同口径，扫到的帧与裁出的帧永远同格）。
    /// 不走「CGContext.draw 整图进缓冲再按物理行段直拷」：webp 解码位图在该路径下
    /// 缓冲行序与 PNG 相反，而换算假设（缓冲行 0 = 图像底部）只对 PNG 成立——
    /// 社区宠物整张图集的行映射被上下翻转（idle 实际播到 review 行的内容）。
    private func crop(asset: PetSpriteAsset, frameIndex: Int) -> NSImage? {
        let grid = asset.grid
        guard frameIndex >= 0, frameIndex < grid.cellCount else { return nil }
        guard let atlas = atlasImage(asset: asset) else { return nil }
        // 图集像素尺寸须与网格标称一致（适配器按实际尺寸计算网格，自有格式按声明校验）。
        guard atlas.width == grid.columns * grid.cellWidth,
              atlas.height == grid.rows * grid.cellHeight else { return nil }
        let column = frameIndex % grid.columns
        let row = frameIndex / grid.columns
        guard let cellImage = atlas.cropping(to: CGRect(
            x: column * grid.cellWidth,
            y: row * grid.cellHeight,
            width: grid.cellWidth,
            height: grid.cellHeight
        )) else { return nil }
        let cropped = NSImage(
            cgImage: cellImage,
            size: NSSize(width: grid.cellWidth, height: grid.cellHeight)
        )
        cropped.capInsets = NSEdgeInsets()
        return cropped
    }
}
