import Foundation

/// 截图目录扫描过滤层：目录事件（复用 DirectoryWatching 原语）→ 防抖 → 扫描 → 过滤 → 上报。
/// 与采集器同一设计：信号与解析分离；本层解析即目录列举，量小、主线程执行。
@MainActor
final class ScreenshotFolderWatcher {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]

    private let watcher: DirectoryWatching
    private let fileManager: FileManager
    private let launchDate: Date
    private let debounceInterval: TimeInterval
    private var known = Set<String>()
    private var pending: Task<Void, Never>?
    private var onNew: ((URL) -> Void)?
    private var onChange: (() -> Void)?
    /// 当前活跃目录：stop→start 重挂后，仍在主队列排队的旧扫描凭它自知过期。
    /// 不加守卫时，旧扫描会用旧目录文件集整体覆盖新基线（known），
    /// 且旧目录新文件会经由已重挂的新回调错误上报。
    private var activeFolder: URL?
    /// 排除集提供者：自家 save/hang 意图写入的文件不自动挂绳。
    var ownWriteConsumer: ((URL) -> Bool)?

    init(watcher: DirectoryWatching = DispatchSourceDirectoryWatcher(),
         fileManager: FileManager = .default,
         launchDate: Date = Date(),
         debounceInterval: TimeInterval = 0.2) {
        self.watcher = watcher
        self.fileManager = fileManager
        self.launchDate = launchDate
        self.debounceInterval = debounceInterval
    }

    /// 桌面目录只接受系统截图（xattr 标记）；专属目录全图片。
    static func isCandidate(_ url: URL, desktopOnlyTagged: Bool) -> Bool {
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
        return desktopOnlyTagged ? ScreenCaptureMetadata.isScreenCapture(url) : true
    }

    func start(folder: URL,
               desktopOnlyTagged: Bool,
               onNew: @escaping (URL) -> Void,
               onChange: @escaping () -> Void) {
        stop()
        self.onNew = onNew
        self.onChange = onChange
        activeFolder = folder
        let files = listing(folder)
        // 启动即扫：基线前文件静默入 known；基线后文件立即补挂（覆盖权限弹窗窗口期）。
        known = Set(files.filter { creationDate($0) < launchDate }.map(\.path))
        for url in files where !known.contains(url.path) && Self.isCandidate(url, desktopOnlyTagged: desktopOnlyTagged) {
            onNew(url)
        }
        known = Set(files.map(\.path))
        watcher.startWatching(url: folder) { [weak self] in
            // 原语回调跑在 .global(qos: .utility)，本层是 @MainActor：
            // 先回主队列再 assumeIsolated，避免后台线程断言崩溃。
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.scheduleScan(folder: folder, desktopOnlyTagged: desktopOnlyTagged)
                }
            }
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        watcher.stopWatching()
        activeFolder = nil   // 使仍在主队列排队的旧扫描过期
        onNew = nil
        onChange = nil
    }

    /// macOS 先写隐藏临时文件再改名：事件后等一拍再扫。
    private func scheduleScan(folder: URL, desktopOnlyTagged: Bool) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.debounceInterval ?? 0.2) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.scan(folder: folder, desktopOnlyTagged: desktopOnlyTagged)
        }
    }

    private func scan(folder: URL, desktopOnlyTagged: Bool) {
        // 重挂守卫：目录事件回调经 main.async 入队，stop→start 后才执行；
        // 此时 folder 是旧目录而 activeFolder 已指向新目录，扫描必须整体放弃。
        guard folder == activeFolder else { return }
        let files = listing(folder)
        for url in files where !known.contains(url.path) {
            guard Self.isCandidate(url, desktopOnlyTagged: desktopOnlyTagged) else { continue }
            if let ownWriteConsumer, ownWriteConsumer(url) { continue }   // 排除集命中：跳过并消费
            onNew?(url)
        }
        known = Set(files.map(\.path))
        onChange?()
    }

    private func listing(_ folder: URL) -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.sorted { creationDate($0) < creationDate($1) }
    }

    private func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
}
