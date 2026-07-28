import Foundation
import AppKit

final class ImageThumbnailer {
    /// 共享缓存：行视图为值类型，需全局单例避免每行/每帧重建实例丢缓存。
    static let shared = ImageThumbnailer()

    private var cache = [String: NSImage]()

    func thumbnail(forPID pid: pid_t, size: NSSize) -> NSImage? {
        let key = "\(pid)"
        if let cached = cache[key] { return cached }
        guard let app = NSRunningApplication(processIdentifier: pid),
              let icon = app.icon else { return nil }
        let resized = NSImage(size: size)
        resized.lockFocus()
        icon.draw(in: NSRect(origin: .zero, size: size))
        resized.unlockFocus()
        cache[key] = resized
        return resized
    }

    func clear() { cache.removeAll() }
}
