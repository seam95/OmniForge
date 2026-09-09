import AppKit
import SwiftUI

/// 桌宠窗口内视图：按行为状态播放图集帧动画，承载单击抚摸与拖拽。
@MainActor
struct PetSpriteView: View {
    @ObservedObject var manager: DesktopPetManager
    /// 宠物资产（nil 时显示占位色块，便于资产缺失时仍可调试窗口行为）。
    var asset: PetSpriteAsset?

    /// 当前动画累计时间，用于推导帧序号。
    @State private var elapsed: TimeInterval = 0

    private var frameTimer: some TimelineSchedule { .animation(minimumInterval: 1.0 / 30.0) }

    var body: some View {
        TimelineView(frameTimer) { context in
            sprite(at: context.date)
        }
        .frame(width: manager.size.pointSize, height: manager.size.pointSize)
        .contentShape(Rectangle())
        .onTapGesture { manager.pet() }
        .gesture(dragGesture)
        .contextMenu { contextMenuItems }
        .onChange(of: manager.behaviorState) { _, _ in
            // 状态切换时重置动画时间轴，避免沿用上一段动画的帧进度。
            elapsed = 0
        }
    }

    /// 右键菜单四项：点击穿透 / 重置位置 / 隐藏宠物 / 打开设置。
    @ViewBuilder
    private var contextMenuItems: some View {
        let strings = manager.strings
        Button {
            manager.setClickThrough(!manager.isClickThrough)
        } label: {
            Label(
                strings.desktopPetClickThrough,
                systemImage: manager.isClickThrough ? "checkmark.circle.fill" : "circle"
            )
        }
        Divider()
        Button(strings.desktopPetResetPosition) { manager.resetPosition() }
        Button(strings.desktopPetHide) { manager.requestHide() }
        Button(strings.desktopPetOpenSettings) { manager.requestOpenSettings() }
    }

    // MARK: - 帧渲染

    @ViewBuilder
    private func sprite(at date: Date) -> some View {
        if let asset, let frameIndex = currentFrameIndex(at: date, asset: asset) {
            if let image = SpriteAtlasImageProvider.shared.image(
                asset: asset,
                frameIndex: frameIndex
            ) {
                Image(nsImage: image)
                    .interpolation(.none)  // 像素最近邻采样，Retina 下保持锐利
                    .resizable()
                    .frame(width: manager.size.pointSize, height: manager.size.pointSize)
            } else {
                placeholder
            }
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

    /// 依据当前状态与已播时间推导图集帧序号。
    private func currentFrameIndex(at date: Date, asset: PetSpriteAsset) -> Int? {
        let animationID: String
        switch manager.behaviorState {
        case .idle: animationID = PetAnimationID.idle
        case .walk: animationID = PetAnimationID.walk
        case .fall, .drag: animationID = PetAnimationID.fall
        case .petted: animationID = PetAnimationID.petted
        }
        guard let animation = asset.animation(id: animationID), !animation.frames.isEmpty else {
            return nil
        }
        let frameCount = animation.frames.count
        let total = animation.frameDuration * Double(frameCount)
        let phase: TimeInterval
        if animation.loops {
            phase = total > 0 ? date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: total) : 0
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

/// 宠物资产定位：内置资产随 App 发布在 Bundle 的 `Pets/<id>/` 下。
/// 测试进程无 app bundle 时，可回退到源码树路径（`searchRoots` 注入）。
enum PetAssetLocator {
    /// 额外搜索根（测试注入源码树 Resources 目录）。
    static var additionalSearchRoots: [URL] = []

    /// 内置宠物资产目录。
    static func directory(for petID: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: petID, withExtension: nil, subdirectory: "Pets") {
            return bundled
        }
        for root in additionalSearchRoots {
            let candidate = root.appendingPathComponent(petID, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("pet.json").path) {
                return candidate
            }
        }
        return nil
    }

    /// 图集文件 URL。
    static func atlasURL(asset: PetSpriteAsset) -> URL? {
        directory(for: asset.id)?.appendingPathComponent(asset.atlasFileName)
    }

    /// 加载内置宠物资产（默认 `cat`）。
    static func loadBuiltIn(petID: String = "cat") -> PetSpriteAsset? {
        guard let directory = directory(for: petID) else { return nil }
        return try? PetSpriteAsset.load(from: directory)
    }
}
