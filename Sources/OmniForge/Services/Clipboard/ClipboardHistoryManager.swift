import AppKit
import Combine
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

/// 剪贴板历史可配置范围与默认值（UI Stepper 与 Manager 共用）。
enum ClipboardHistoryLimits {
    static let minRetentionDays = 1
    static let maxRetentionDays = 30
    static let defaultRetentionDays = 7

    static let minMaxEntries = 50
    static let maxMaxEntries = 1500
    static let defaultMaxEntries = 250
    static let maxEntriesStep = 10

    static func clampRetentionDays(_ value: Int) -> Int {
        min(max(value, minRetentionDays), maxRetentionDays)
    }

    static func clampMaxEntries(_ value: Int) -> Int {
        min(max(value, minMaxEntries), maxMaxEntries)
    }
}

@MainActor
final class ClipboardHistoryManager: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry]
    @Published var retentionDays: Int {
        didSet {
            let normalized = ClipboardHistoryLimits.clampRetentionDays(retentionDays)
            if normalized != retentionDays {
                retentionDays = normalized
                return
            }
            guard retentionDays != oldValue else { return }
            userDefaults.set(retentionDays, forKey: UserDefaultsKeys.clipboardRetentionDays)
            pruneAndPersist()
        }
    }
    @Published var maxEntries: Int {
        didSet {
            let normalized = ClipboardHistoryLimits.clampMaxEntries(maxEntries)
            if normalized != maxEntries {
                maxEntries = normalized
                return
            }
            guard maxEntries != oldValue else { return }
            userDefaults.set(maxEntries, forKey: UserDefaultsKeys.clipboardMaxEntries)
            pruneAndPersist()
        }
    }

    private let store: ClipboardStore
    private let userDefaults: UserDefaults
    private let pasteboard: PasteboardClient
    private var pollTimer: Timer?
    private var lastChangeCount: Int?
    /// 监控意图标志 — startMonitoring 被调用且未被 stopMonitoring 清除时为 true。
    /// 与 pollTimer 解耦：测试环境下 pollTimer 不会创建，但意图仍可观测。
    private var isMonitoringActive = false

    /// 当前是否正在监控剪贴板（供 FeatureRuntime binding 和测试使用）
    var isMonitoring: Bool {
        isMonitoringActive
    }

    deinit {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    init(
        store: ClipboardStore = ClipboardHistoryManager.makeDefaultStore(),
        userDefaults: UserDefaults = .standard,
        pasteboard: PasteboardClient = SystemPasteboardClient()
    ) {
        self.store = store
        self.userDefaults = userDefaults
        self.pasteboard = pasteboard

        let savedRetention = userDefaults.integer(forKey: UserDefaultsKeys.clipboardRetentionDays)
        let initialRetention = savedRetention > 0
            ? ClipboardHistoryLimits.clampRetentionDays(savedRetention)
            : ClipboardHistoryLimits.defaultRetentionDays

        let savedMax = userDefaults.integer(forKey: UserDefaultsKeys.clipboardMaxEntries)
        let initialMaxEntries = savedMax > 0
            ? ClipboardHistoryLimits.clampMaxEntries(savedMax)
            : ClipboardHistoryLimits.defaultMaxEntries

        self.retentionDays = initialRetention
        self.maxEntries = initialMaxEntries

        let loaded = store.loadEntries()
        let pruned = ClipboardHistoryManager.pruneEntries(
            loaded,
            retentionDays: initialRetention,
            maxEntries: initialMaxEntries
        )
        self.entries = pruned

        // 增量删除被裁剪的条目
        let removedIDs = Set(loaded.map(\.id)).subtracting(Set(pruned.map(\.id)))
        if !removedIDs.isEmpty {
            store.deleteEntries(ids: removedIDs)
        }
    }

    func startMonitoring(interval: TimeInterval = 0.4) {
        guard pollTimer == nil else { return }
        isMonitoringActive = true
        guard !isRunningUnitTests else { return }
        lastChangeCount = pasteboard.changeCount
        pollTimer = Timer.scheduledTimer(
            timeInterval: interval,
            target: self,
            selector: #selector(handleTimerTick),
            userInfo: nil,
            repeats: true
        )
    }

    func stopMonitoring() {
        isMonitoringActive = false
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func releaseMemory() {
        store.releaseMemory()
    }

    func addEntry(_ entry: ClipboardEntry) {
        // 全量去重：内容相同则移到首位，不新增
        if let existingIndex = entries.firstIndex(where: { $0.type == entry.type && isContentEqual($0, entry) }) {
            let existing = entries[existingIndex]
            if existingIndex == 0 { return }
            let moved = ClipboardEntry(
                id: existing.id,
                createdAt: Date(),
                type: entry.type,
                preview: entry.preview,
                sourceAppBundleID: entry.sourceAppBundleID,
                sourceAppName: entry.sourceAppName,
                content: entry.content,
                thumbnailData: entry.thumbnailData,
                blobSize: entry.blobSize,
                imageWidth: entry.imageWidth,
                imageHeight: entry.imageHeight,
                contentHash: entry.contentHash
            )
            entries.remove(at: existingIndex)
            entries.insert(moved.lightweight(), at: 0)
            store.saveEntry(moved)
            return
        }
        store.saveEntry(entry)                      // 完整写入 DB
        entries.insert(entry.lightweight(), at: 0)   // 内存只存轻量版
        pruneAndPersist()
    }

    func pollPasteboard() {
        let changeCount = pasteboard.changeCount
        if let lastChangeCount, lastChangeCount == changeCount {
            return
        }
        lastChangeCount = changeCount

        guard let entry = captureEntry() else { return }
        addEntry(entry)
    }

    /// 获取条目的完整内容（按需从 DB 加载 blob）
    func fullContent(for entryID: UUID) -> ClipboardContent? {
        // 已加载文本与 url/files 类型可直接返回。
        if let entry = entries.first(where: { $0.id == entryID }) {
            switch entry.content {
            case .text(let text?):
                return .text(text)
            case .url, .files:
                return entry.content
            default:
                break
            }
        }
        return store.loadFullContent(for: entryID)
    }

    /// 后台图片加载通道：绕过主线程读取完整 blob（SPEC §9.3.2）。
    /// 需在主线程捕获 `store`（已按隔离规则访问）后传入；本函数非隔离，
    /// 内部只调用 store 的数据库读取（GRDB 串行队列实现线程安全）。
    nonisolated static func loadImagePayload(
        for entryID: UUID,
        store: ClipboardStore
    ) -> ClipboardContent? {
        store.loadFullContent(for: entryID)
    }

    /// 主线程访问器：视图在 body 阶段捕获 store 引用，供后台加载闭包使用。
    var storeForBackgroundLoad: ClipboardStore? { store }

    static func pruneEntries(
        _ entries: [ClipboardEntry],
        retentionDays: Int,
        maxEntries: Int,
        now: Date = Date()
    ) -> [ClipboardEntry] {
        let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays) * 24 * 60 * 60)
        let filtered = entries.filter { $0.createdAt >= cutoff }
            .sorted { $0.createdAt > $1.createdAt }
        if maxEntries <= 0 {
            return filtered
        }
        return Array(filtered.prefix(maxEntries))
    }

    private func pruneAndPersist() {
        let before = entries
        entries = ClipboardHistoryManager.pruneEntries(
            entries,
            retentionDays: retentionDays,
            maxEntries: maxEntries
        )
        // 增量删除被裁剪的条目
        let removedIDs = Set(before.map(\.id)).subtracting(Set(entries.map(\.id)))
        if !removedIDs.isEmpty {
            store.deleteEntries(ids: removedIDs)
        }
    }

    /// 内容相等比较：text/url/files 直接比较值，blob 类型比较 contentHash
    private func isContentEqual(_ lhs: ClipboardEntry, _ rhs: ClipboardEntry) -> Bool {
        lhs.type == rhs.type
            && lhs.contentHash != nil
            && lhs.contentHash == rhs.contentHash
    }

    private func captureEntry() -> ClipboardEntry? {
        let fileURLs = pasteboard.readFileURLs()
        if !fileURLs.isEmpty {
            return makeEntry(
                type: .file,
                preview: previewForFiles(fileURLs),
                content: .files(fileURLs)
            )
        }

        if let url = pasteboard.readURL() {
            return makeEntry(
                type: .url,
                preview: url.absoluteString,
                content: .url(url)
            )
        }

        if let imageData = pasteboard.readImageData() {
            return makeEntry(
                type: .image,
                preview: "Image",
                content: .image(imageData),
                thumbnailData: makeImageThumbnailData(from: imageData)
            )
        }

        if let text = pasteboard.readText() {
            if let url = URL(string: text), url.scheme != nil {
                return makeEntry(
                    type: .url,
                    preview: text,
                    content: .url(url)
                )
            }
            return makeEntry(
                type: .text,
                preview: previewForText(text),
                content: .text(text)
            )
        }

        if let rtfData = pasteboard.readRTFData() {
            return makeEntry(
                type: .rtf,
                preview: "RTF",
                content: .rtf(rtfData)
            )
        }

        return nil
    }

    @objc private func handleTimerTick() {
        pollPasteboard()
    }

    private func makeEntry(
        type: ClipboardContentType,
        preview: String,
        content: ClipboardContent,
        thumbnailData: Data? = nil
    ) -> ClipboardEntry {
        let app = NSWorkspace.shared.frontmostApplication
        return ClipboardEntry(
            id: UUID(),
            createdAt: Date(),
            type: type,
            preview: preview,
            sourceAppBundleID: app?.bundleIdentifier,
            sourceAppName: app?.localizedName,
            content: content,
            thumbnailData: thumbnailData
        )
    }

    private func makeImageThumbnailData(from imageData: Data) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(imageData as CFData, options as CFDictionary) else {
            return nil
        }

        let maxPixelSize = 44
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        let destinationData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(destinationData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return destinationData as Data
    }

    private func previewForText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 80 {
            return trimmed
        }
        let index = trimmed.index(trimmed.startIndex, offsetBy: 80)
        return String(trimmed[..<index]) + "…"
    }

    private func previewForFiles(_ urls: [URL]) -> String {
        guard let first = urls.first else { return "Files" }
        if urls.count == 1 {
            return first.lastPathComponent
        }
        return "\(first.lastPathComponent) 等 \(urls.count) 个文件"
    }

    private var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    nonisolated static func makeDefaultStore() -> ClipboardStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let root = (base ?? FileManager.default.temporaryDirectory)
        let directory = root
            .appendingPathComponent("OmniForge")
            .appendingPathComponent("ClipboardHistory")
        // 一次性迁移：老版本数据位于 `InputLock/ClipboardHistory`，改名后搬迁到 `OmniForge/ClipboardHistory`。
        let legacyDirectory = root
            .appendingPathComponent("InputLock")
            .appendingPathComponent("ClipboardHistory")
        LegacyDataMigrator.migrateDirectory(from: legacyDirectory, to: directory)
        let databaseURL = directory.appendingPathComponent("entries.sqlite")
        let removeLegacyStoreFiles = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        return GRDBClipboardStore(
            databaseURL: databaseURL,
            legacyStoreDirectoryURL: directory,
            removeLegacyStoreFiles: removeLegacyStoreFiles
        )
    }
}
