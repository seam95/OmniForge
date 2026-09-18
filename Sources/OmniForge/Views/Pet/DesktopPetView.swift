import AppKit
import SwiftUI

/// 桌宠窗口内视图：呈现 Manager 统一显示快照（唯一帧真相），承载单击抚摸与右键菜单。
/// 帧选择 / 看向 / 悬停等一切显示裁决都在 Manager 的 tick 中完成；
/// 本视图只随帧时钟轮询读取快照呈现，不做二次推导，也不在 body 中改窗口状态。
@MainActor
struct PetSpriteView: View {
    @ObservedObject var manager: DesktopPetManager
    /// 宠物资产（nil 时显示占位色块，便于资产缺失时仍可调试窗口行为）。
    var asset: PetSpriteAsset?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            sprite
        }
        .frame(width: manager.petSize.width, height: manager.petSize.height)
        .contentShape(Rectangle())
        .onTapGesture { manager.pet() }
        .contextMenu { contextMenuItems }
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
    private var sprite: some View {
        // 固定双层结构：占位只在资产缺失时出现（调试窗口行为用）；
        // 有资产时绝不渲染底色——像素图集帧有大量透明像素，
        // 常驻底色会把宠物周围整块染色（蓝色占位曾透出为背景色块）。
        ZStack {
            if asset == nil { placeholder }
            if let snapshot = manager.displaySnapshot,
               let image = SpriteAtlasImageProvider.shared.image(
                asset: snapshot.asset,
                frameIndex: snapshot.frameIndex
               ) {
                Image(nsImage: image)
                    .interpolation(.none)  // 像素最近邻采样，Retina 下保持锐利
                    .resizable()
                    .frame(width: snapshot.size.width, height: snapshot.size.height)
                    // 单朝向素材在向左显示时水平镜像（镜像标记来自显示快照）。
                    .scaleEffect(x: snapshot.mirrored ? -1 : 1, y: 1)
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

    // MARK: - 拖拽

    // 拖拽不再由 SwiftUI 承载：视图层任何拖动都会按手势事件率逐次移动窗口，
    // 移动间隔不均（抖动）且与 30Hz 图层内容提交竞争（频闪）。
    // 现由 PetHostingView（窗口 contentView）在越过阈值后启动系统原生拖动会话，
    // 由 WindowServer 统一批处理移动并与显示刷新对齐；状态迁移经
    // manager.beginDrag / endDrag 回调触发。单击抚摸仍由上方 onTapGesture 处理。
}

/// 图集切片缓存：按资产与帧序号缓存切好的图，避免每帧重切。
/// 渲染（NSImage）与命中层（CGImage 像素）共享同一裁剪结果。
/// 图集缓存带 LRU 上限：整张图集解码位图约 11-14MB/张，无上限时每切换
/// 一只宠物永久累积一张（曾实测一天 38 张 = 417MB Image IO 脏页）。
@MainActor
final class SpriteAtlasImageProvider {
    static let shared = SpriteAtlasImageProvider()

    /// 图集解码器（默认磁盘解码；测试注入以观测解码次数）。
    typealias AtlasDecoder = (URL) -> CGImage?

    /// 图集缓存上限（张）：当前宠物 + 近期切换的两只，内存封顶约 40MB。
    static let atlasCacheLimit = 3

    private var atlasImageCache: [String: CGImage] = [:]
    /// LRU 序（尾端 = 最近使用）：超限时逐出首端（最久未用）。
    /// 当前宠物每帧请求会持续命中并续期，因此活跃宠物永不逐出。
    private var atlasUsageOrder: [String] = []
    /// 帧切片按资产分组：切片 CGImage 共享父图集 backing store，
    /// 必须随父图集同进同出——残留切片会把已逐出的父图集位图继续钉在内存。
    private var frameCache: [String: [Int: CGImage]] = [:]
    private let decodeAtlas: AtlasDecoder

    init(decodeAtlas: @escaping AtlasDecoder = SpriteAtlasImageProvider.defaultAtlasDecoder) {
        self.decodeAtlas = decodeAtlas
    }

    static func defaultAtlasDecoder(url: URL) -> CGImage? {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return cgImage
    }

    /// 取指定帧的切图；图集缺失时返回 nil（调用方回退占位）。
    func image(asset: PetSpriteAsset, frameIndex: Int) -> NSImage? {
        guard let cropped = frameCGImage(asset: asset, frameIndex: frameIndex) else {
            return nil
        }
        let image = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        image.capInsets = NSEdgeInsets()
        return image
    }

    /// 取指定帧的 CGImage（命中层读像素用，与渲染同一份裁剪缓存）。
    func frameCGImage(asset: PetSpriteAsset, frameIndex: Int) -> CGImage? {
        if let cached = frameCache[asset.id]?[frameIndex] {
            // 切片命中也要续期：渲染的常态路径是逐帧命中切片（不经过图集层），
            // 活跃宠物的续期必须在此发生，否则会被逐出、下一帧重新解码整图。
            touchAtlasUsage(asset.id)
            return cached
        }
        guard let cropped = crop(asset: asset, frameIndex: frameIndex) else {
            return nil
        }
        frameCache[asset.id, default: [:]][frameIndex] = cropped
        return cropped
    }

    /// 清空缓存（资产热更新或测试用）。
    func clearCache() {
        atlasImageCache.removeAll()
        atlasUsageOrder.removeAll()
        frameCache.removeAll()
    }

    /// 图集 CGImage：按资产缓存（LRU 上限），避免逐帧重复解码。
    private func atlasImage(asset: PetSpriteAsset) -> CGImage? {
        if let cached = atlasImageCache[asset.id] {
            touchAtlasUsage(asset.id)
            return cached
        }
        guard let url = PetAssetLocator.atlasURL(asset: asset),
              let cgImage = decodeAtlas(url) else {
            return nil
        }
        atlasImageCache[asset.id] = cgImage
        atlasUsageOrder.append(asset.id)
        evictStaleAtlasesIfNeeded()
        return cgImage
    }

    /// 命中续期：移到 LRU 序尾。
    private func touchAtlasUsage(_ id: String) {
        guard let index = atlasUsageOrder.firstIndex(of: id) else { return }
        atlasUsageOrder.remove(at: index)
        atlasUsageOrder.append(id)
    }

    /// 逐出最久未用的图集及其全部帧切片。
    private func evictStaleAtlasesIfNeeded() {
        while atlasUsageOrder.count > Self.atlasCacheLimit {
            let evicted = atlasUsageOrder.removeFirst()
            atlasImageCache.removeValue(forKey: evicted)
            frameCache.removeValue(forKey: evicted)
        }
    }

    /// 从图集裁出单元格。
    ///
    /// 用 `CGImage.cropping` 直取像素：行 0 = 图集文件顶部，该语义对 PNG 与 webp
    /// 一致（与 `PetdexAssetAdapter` 的占用扫描同口径，扫到的帧与裁出的帧永远同格）。
    /// 不走「CGContext.draw 整图进缓冲再按物理行段直拷」：webp 解码位图在该路径下
    /// 缓冲行序与 PNG 相反，而换算假设（缓冲行 0 = 图像底部）只对 PNG 成立——
    /// 社区宠物整张图集的行映射被上下翻转（idle 实际播到 review 行的内容）。
    private func crop(asset: PetSpriteAsset, frameIndex: Int) -> CGImage? {
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
        return cellImage
    }
}
