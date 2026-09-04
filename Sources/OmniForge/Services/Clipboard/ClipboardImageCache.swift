import AppKit

@MainActor
final class ClipboardImageCache {
    static let shared = ClipboardImageCache()

    /// 按显示像素降采样的详情图片缓存。
    private let detailCache: NSCache<NSString, NSImage>

    /// 缩略图缓存（列表行用），容量大
    private let thumbnailCache: NSCache<NSUUID, NSImage>

    private init() {
        detailCache = NSCache()
        detailCache.countLimit = 5
        detailCache.totalCostLimit = 50 * 1024 * 1024  // 50 MB

        thumbnailCache = NSCache()
        thumbnailCache.countLimit = 200
    }

    /// 测试隔离实例（默认缓存容量）。
    init(testInstance: Void = ()) {
        detailCache = NSCache()
        detailCache.countLimit = 5
        detailCache.totalCostLimit = 50 * 1024 * 1024  // 50 MB

        thumbnailCache = NSCache()
        thumbnailCache.countLimit = 200
    }

    /// 只查询详情图片缓存（零成本命中；未命中返回 nil，不触发加载/解码）。
    func cachedDetailImage(for entryID: UUID, maxPixelSize: Int) -> NSImage? {
        guard maxPixelSize > 0 else { return nil }
        let key = detailKey(entryID: entryID, maxPixelSize: maxPixelSize)
        return detailCache.object(forKey: key)
    }

    /// 后台加载/解码完成后回写详情缓存（主线程调用）。
    func storeDetailImage(_ image: NSImage, for entryID: UUID, maxPixelSize: Int) {
        let key = detailKey(entryID: entryID, maxPixelSize: maxPixelSize)
        let cost = estimateImageCost(image)
        detailCache.setObject(image, forKey: key, cost: cost)
    }

    /// 获取详情图片；缓存键包含显示尺寸，避免复用分辨率不足的图片。
    func detailImage(
        for entryID: UUID,
        maxPixelSize: Int,
        loader: () -> Data?
    ) -> NSImage? {
        guard maxPixelSize > 0 else { return nil }
        let key = detailKey(entryID: entryID, maxPixelSize: maxPixelSize)
        if let cached = detailCache.object(forKey: key) {
            return cached
        }
        guard let data = loader(),
              let image = ClipboardImageDownsampler.image(
                  data: data,
                  maxPixelSize: maxPixelSize
              ) else {
            return nil
        }
        let cost = estimateImageCost(image)
        detailCache.setObject(image, forKey: key, cost: cost)
        return image
    }

    private func detailKey(entryID: UUID, maxPixelSize: Int) -> NSString {
        "\(entryID.uuidString):\(maxPixelSize)" as NSString
    }

    /// 获取列表行缩略图，未命中时从 data 创建
    func thumbnailImage(for entryID: UUID, data: Data?) -> NSImage? {
        let key = entryID as NSUUID
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        guard let data, let image = NSImage(data: data) else { return nil }
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    func clearAll() {
        detailCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
    }

    private func estimateImageCost(_ image: NSImage) -> Int {
        guard let rep = image.representations.first else { return 0 }
        return rep.pixelsWide * rep.pixelsHigh * 4
    }
}
