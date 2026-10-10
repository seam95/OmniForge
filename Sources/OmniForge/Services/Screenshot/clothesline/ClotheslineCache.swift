import Foundation

/// 晾衣绳的临时缓存目录：编辑器确认（✓）后的截图落在那里，是「缓存最近
/// n 张」的存储底座。目录由本应用独占——超出容量即销毁，不碰用户的
/// 桌面/保存目录里的任何文件。
enum ClotheslineCache {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OmniForge/ClotheslineCache", isDirectory: true)
    }()

    /// 文件是否在本缓存目录内（决定丢弃/淘汰时是否销毁文件）。
    static func isCacheFile(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
    }
}
