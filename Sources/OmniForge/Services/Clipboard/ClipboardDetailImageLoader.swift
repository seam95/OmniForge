import AppKit
import Foundation

/// 剪贴板详情图片异步加载器（SPEC §9.3）：主线程只应用结果，blob 读取与
/// 降采样解码在后台执行。竞态防护：每次 `request` 自增 generation，旧请求
/// 晚到结果（解码完成时已切走）直接丢弃，不覆盖当前展示。
@MainActor
final class ClipboardDetailImageLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var failed = false

    private let cache: ClipboardImageCache
    private var generation = 0

    init(cache: ClipboardImageCache = .shared) {
        self.cache = cache
    }

    /// 发起/更新加载请求。先查缓存（命中零成本立即展示）；未命中则后台加载。
    func request(
        entryID: UUID,
        maxPixelSize: Int,
        loadPayload: @escaping () -> ClipboardContent?
    ) {
        generation &+= 1
        let requestGeneration = generation
        image = nil
        failed = false

        guard maxPixelSize > 0 else { return }
        if let cached = cache.cachedDetailImage(
            for: entryID,
            maxPixelSize: maxPixelSize
        ) {
            image = cached
            return
        }

        Task { [weak self] in
            guard let self else { return }
            // 后台读取完整 blob（数据库/磁盘）。
            let payload = await Task.detached(priority: .utility) {
                loadPayload()
            }.value
            guard let payload, case .image(let data) = payload, let data else {
                guard !Task.isCancelled, self.generation == requestGeneration else { return }
                self.failed = true
                return
            }
            // 后台降采样解码；主线程只应用最终 NSImage。
            let decoded = await Task.detached(priority: .utility) {
                ClipboardImageDownsampler.image(data: data, maxPixelSize: maxPixelSize)
            }.value
            guard let decoded else {
                guard !Task.isCancelled, self.generation == requestGeneration else { return }
                self.failed = true
                return
            }
            guard !Task.isCancelled, self.generation == requestGeneration else {
                return // 旧请求晚到：不覆盖新选择
            }
            self.cache.storeDetailImage(
                decoded, for: entryID, maxPixelSize: maxPixelSize
            )
            self.image = decoded
        }
    }
}
