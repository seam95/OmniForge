import XCTest
@testable import OmniForge

@MainActor
final class ClipboardHistoryManagerTests: XCTestCase {
    func test_defaultsPersistToUserDefaults() {
        let defaults = UserDefaults(suiteName: "ClipboardHistoryManagerTests")!
        defaults.removePersistentDomain(forName: "ClipboardHistoryManagerTests")

        let store = FakeClipboardStore(entries: [])
        let manager = ClipboardHistoryManager(store: store, userDefaults: defaults)

        XCTAssertEqual(manager.retentionDays, ClipboardHistoryLimits.defaultRetentionDays)
        XCTAssertEqual(manager.maxEntries, ClipboardHistoryLimits.defaultMaxEntries)

        manager.retentionDays = 3
        manager.maxEntries = 120

        let reloaded = ClipboardHistoryManager(store: store, userDefaults: defaults)
        XCTAssertEqual(reloaded.retentionDays, 3)
        XCTAssertEqual(reloaded.maxEntries, 120)
    }

    func test_limitsClampRetentionAndMaxEntries() {
        let defaults = UserDefaults(suiteName: "ClipboardHistoryManagerTests_limits")!
        defaults.removePersistentDomain(forName: "ClipboardHistoryManagerTests_limits")
        let manager = ClipboardHistoryManager(store: FakeClipboardStore(entries: []), userDefaults: defaults)

        manager.retentionDays = 0
        XCTAssertEqual(manager.retentionDays, ClipboardHistoryLimits.minRetentionDays)
        manager.retentionDays = 999
        XCTAssertEqual(manager.retentionDays, ClipboardHistoryLimits.maxRetentionDays)

        manager.maxEntries = 1
        XCTAssertEqual(manager.maxEntries, ClipboardHistoryLimits.minMaxEntries)
        manager.maxEntries = 10_000
        XCTAssertEqual(manager.maxEntries, ClipboardHistoryLimits.maxMaxEntries)
    }

    func test_limitConstantsMatchProductContract() {
        XCTAssertEqual(ClipboardHistoryLimits.maxRetentionDays, 30)
        XCTAssertEqual(ClipboardHistoryLimits.maxMaxEntries, 1500)
        XCTAssertEqual(ClipboardHistoryLimits.minMaxEntries, 50)
        XCTAssertEqual(ClipboardHistoryLimits.defaultMaxEntries, 250)
        XCTAssertEqual(ClipboardHistoryLimits.defaultRetentionDays, 7)
    }

    func test_addEntryDeduplicatesLatest() {
        let store = FakeClipboardStore(entries: [])
        let defaults = UserDefaults(suiteName: "ClipboardHistoryManagerTests_dedup")!
        defaults.removePersistentDomain(forName: "ClipboardHistoryManagerTests_dedup")
        let manager = ClipboardHistoryManager(store: store, userDefaults: defaults)

        let entry = ClipboardEntry(
            id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
            createdAt: Date(),
            type: .text,
            preview: "Same",
            sourceAppBundleID: nil,
            sourceAppName: nil,
            content: .text("Same")
        )

        manager.addEntry(entry)
        manager.addEntry(entry)

        XCTAssertEqual(manager.entries.count, 1)
    }

    func test_pruneRemovesExpiredAndLimitsCount() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            ClipboardEntry(id: UUID(), createdAt: now, type: .text, preview: "1", sourceAppBundleID: nil, sourceAppName: nil, content: .text("1")),
            ClipboardEntry(id: UUID(), createdAt: now.addingTimeInterval(-60 * 60 * 24 * 10), type: .text, preview: "old", sourceAppBundleID: nil, sourceAppName: nil, content: .text("old")),
            ClipboardEntry(id: UUID(), createdAt: now.addingTimeInterval(-60 * 60 * 24 * 2), type: .text, preview: "2", sourceAppBundleID: nil, sourceAppName: nil, content: .text("2")),
            ClipboardEntry(id: UUID(), createdAt: now.addingTimeInterval(-60 * 60 * 24 * 1), type: .text, preview: "3", sourceAppBundleID: nil, sourceAppName: nil, content: .text("3"))
        ]

        let pruned = ClipboardHistoryManager.pruneEntries(
            entries,
            retentionDays: 7,
            maxEntries: 2,
            now: now
        )

        XCTAssertEqual(pruned.count, 2)
        XCTAssertTrue(pruned.allSatisfy { $0.createdAt >= now.addingTimeInterval(-60 * 60 * 24 * 7) })
    }

    func test_makeDefaultStoreUsesGRDBClipboardStore() {
        let store = ClipboardHistoryManager.makeDefaultStore()

        XCTAssertTrue(store is GRDBClipboardStore)
    }

    func test_duplicateLightweightTextSavesIncomingFullContent() {
        let original = makeTextEntry(id: UUID(), text: "same")
        let store = FakeClipboardStore(entries: [original.lightweight()])
        let defaults = UserDefaults(suiteName: "ClipboardHistoryManagerTests_duplicateText")!
        defaults.removePersistentDomain(forName: "ClipboardHistoryManagerTests_duplicateText")
        let manager = ClipboardHistoryManager(store: store, userDefaults: defaults)

        manager.addEntry(makeTextEntry(id: UUID(), text: "other"))
        manager.addEntry(makeTextEntry(id: UUID(), text: "same"))

        XCTAssertEqual(store.savedEntries.last?.content, .text("same"))
        XCTAssertEqual(manager.entries.first?.content, .text(nil))
    }

    func test_releaseMemory_forwardsToStore() {
        let store = FakeClipboardStore(entries: [])
        let defaults = UserDefaults(suiteName: "ClipboardHistoryManagerTests_releaseMemory")!
        defaults.removePersistentDomain(forName: "ClipboardHistoryManagerTests_releaseMemory")
        let manager = ClipboardHistoryManager(store: store, userDefaults: defaults)

        manager.releaseMemory()

        XCTAssertEqual(store.releaseMemoryCallCount, 1)
    }

    // MARK: - 采集分类顺序（图片数据优先于文件 URL）

    func test_capture_prefersImageWhenBothImageDataAndFileURLPresent() {
        let pasteboard = FakeHistoryPasteboardClient()
        let manager = ClipboardHistoryManager(
            store: FakeClipboardStore(entries: []),
            userDefaults: UserDefaults(suiteName: "ClipboardHistoryManagerTests_imgfirst")!,
            pasteboard: pasteboard
        )
        pasteboard.imageData = Self.tinyPNG()
        pasteboard.fileURLs = [URL(fileURLWithPath: "/tmp/shot.png")]

        pasteboard.changeCountValue += 1
        manager.pollPasteboard()

        XCTAssertEqual(manager.entries.count, 1)
        XCTAssertEqual(manager.entries.first?.type, .image, "PNG 数据 + 文件 URL 双写应按图片归档")
        XCTAssertNotNil(manager.entries.first?.thumbnailData, "图片条目必须有缩略图")
        guard case .image = manager.entries.first?.content else {
            return XCTFail("content 应为 .image")
        }
    }

    func test_capture_fileEntryWhenOnlyFileURL() {
        let pasteboard = FakeHistoryPasteboardClient()
        let manager = ClipboardHistoryManager(
            store: FakeClipboardStore(entries: []),
            userDefaults: UserDefaults(suiteName: "ClipboardHistoryManagerTests_fileonly")!,
            pasteboard: pasteboard
        )
        pasteboard.fileURLs = [URL(fileURLWithPath: "/tmp/doc.pdf")]

        pasteboard.changeCountValue += 1
        manager.pollPasteboard()

        XCTAssertEqual(manager.entries.count, 1)
        XCTAssertEqual(manager.entries.first?.type, .file, "纯文件复制仍按文件归档")
    }

    func test_capture_rejectsUndecodableImageStub() {
        let pasteboard = FakeHistoryPasteboardClient()
        let manager = ClipboardHistoryManager(
            store: FakeClipboardStore(entries: []),
            userDefaults: UserDefaults(suiteName: "ClipboardHistoryManagerTests_stub")!,
            pasteboard: pasteboard
        )
        // 微信式占位符：.png 槽位只放 4 字节魔数（真实读取层会过滤掉；
        // 此处直接经假件注入，验证采集层的第二道防线）。
        pasteboard.imageData = Data([0x89, 0x50, 0x4E, 0x47])

        pasteboard.changeCountValue += 1
        manager.pollPasteboard()

        XCTAssertTrue(manager.entries.isEmpty, "不可解码的图片数据不得入库（否则永远无法预览）")
    }

    /// 8×8 合法 PNG（远大于 32 字节阈值）。
    static func tinyPNG() -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            fatalError("tinyPNG fixture failed")
        }
        return png
    }

    // MARK: - 采集暂停窗口（⌘C 兜底取词的零污染保障）

    func test_suspendCapture_skipsChangesAndResumeDiscardsThem() {
        let pasteboard = FakeHistoryPasteboardClient()
        let manager = ClipboardHistoryManager(
            store: FakeClipboardStore(entries: []),
            userDefaults: UserDefaults(suiteName: "ClipboardHistoryManagerTests_suspend")!,
            pasteboard: pasteboard
        )

        // 暂停窗口内：临时写入（模拟 ⌘C 的选中内容 + 恢复原内容）一律不采集。
        manager.suspendCapture()
        pasteboard.changeCountValue += 1
        pasteboard.text = "模拟 ⌘C 的临时内容"
        manager.pollPasteboard()
        XCTAssertTrue(manager.entries.isEmpty, "暂停期间不采集")

        pasteboard.changeCountValue += 1
        pasteboard.text = "恢复的原内容"
        manager.resumeCapture()
        manager.pollPasteboard()
        XCTAssertTrue(manager.entries.isEmpty, "resume 拉平基线，暂停期间变化整体丢弃")

        // 恢复后：新变化正常采集。
        pasteboard.changeCountValue += 1
        pasteboard.text = "用户真实复制"
        manager.pollPasteboard()
        XCTAssertEqual(manager.entries.count, 1)
        XCTAssertEqual(manager.entries.first?.preview, "用户真实复制")
    }

    func test_suspendCapture_isReentrant() {
        let pasteboard = FakeHistoryPasteboardClient()
        let manager = ClipboardHistoryManager(
            store: FakeClipboardStore(entries: []),
            userDefaults: UserDefaults(suiteName: "ClipboardHistoryManagerTests_suspend2")!,
            pasteboard: pasteboard
        )

        manager.suspendCapture()
        manager.suspendCapture()
        manager.resumeCapture()
        pasteboard.changeCountValue += 1
        pasteboard.text = "仍处于暂停"
        manager.pollPasteboard()
        XCTAssertTrue(manager.entries.isEmpty, "嵌套计数未归零时保持暂停")

        manager.resumeCapture()
        pasteboard.changeCountValue += 1
        pasteboard.text = "归零后恢复采集"
        manager.pollPasteboard()
        XCTAssertEqual(manager.entries.count, 1)
    }

    // MARK: - 敏感内容跳过（密码管理器 concealed 标记）

    func test_poll_skipsConcealedContent_andAdvancesChangeCount() {
        let pasteboard = FakeHistoryPasteboardClient()
        let defaults = UserDefaults(suiteName: "ClipboardHistoryManagerTests_concealed")!
        defaults.removePersistentDomain(forName: "ClipboardHistoryManagerTests_concealed")
        let manager = ClipboardHistoryManager(
            store: FakeClipboardStore(entries: []),
            userDefaults: defaults,
            pasteboard: pasteboard
        )

        // 模拟密码管理器复制密码：明文与 concealed 标记同时存在于剪贴板。
        pasteboard.isConcealed = true
        pasteboard.text = "s3cret-password"
        pasteboard.changeCountValue += 1
        manager.pollPasteboard()

        XCTAssertTrue(manager.entries.isEmpty, "concealed 标记的内容不得进入历史")
        XCTAssertEqual(pasteboard.contentReadCount, 0, "concealed 检查必须发生在读取任何剪贴板内容之前")

        // lastChangeCount 应已推进：即使密码管理器随后清除 concealed 标记，
        // 同一 changeCount 对应的这轮内容也不得在后续 poll 中被补采集。
        pasteboard.isConcealed = false
        manager.pollPasteboard()
        XCTAssertTrue(manager.entries.isEmpty, "已跳过的变更不得重复判定")

        // 标记清除后的新一轮变更恢复正常采集。
        pasteboard.changeCountValue += 1
        pasteboard.text = "正常复制"
        manager.pollPasteboard()
        XCTAssertEqual(manager.entries.count, 1)
        XCTAssertEqual(manager.entries.first?.preview, "正常复制")
    }

    // MARK: - 文本 URL 分类（scheme 白名单）

    /// 表驱动：含冒号的普通文本不得因 Foundation 的宽容解析被误判为 URL
    /// （否则粘贴回会变成 "Re:%20Meeting%20tomorrow" 这类被百分号编码的乱码）。
    func test_capture_classifiesTextBySchemeWhitelist() {
        let cases: [(text: String, expected: ClipboardContentType, note: String)] = [
            ("Re: Meeting tomorrow", .text, "含冒号的普通文本不得判为 URL"),
            ("TODO: fix", .text, "含冒号的普通文本不得判为 URL"),
            ("https://a.b/c", .url, "白名单 https 且有 host"),
            ("mailto:a@b.c", .url, "白名单 mailto 直接收"),
            ("file:///tmp/x", .url, "白名单 file 直接收"),
            ("myapp://x", .text, "非白名单 scheme 归文本原样保存"),
            ("http://", .text, "http 无 host 归文本原样保存"),
        ]

        for testCase in cases {
            let pasteboard = FakeHistoryPasteboardClient()
            let defaults = UserDefaults(suiteName: "ClipboardHistoryManagerTests_urlclass")!
            defaults.removePersistentDomain(forName: "ClipboardHistoryManagerTests_urlclass")
            let store = FakeClipboardStore(entries: [])
            let manager = ClipboardHistoryManager(
                store: store,
                userDefaults: defaults,
                pasteboard: pasteboard
            )

            pasteboard.text = testCase.text
            pasteboard.changeCountValue += 1
            manager.pollPasteboard()

            XCTAssertEqual(manager.entries.count, 1, "「\(testCase.text)」应被采集：\(testCase.note)")
            XCTAssertEqual(manager.entries.first?.type, testCase.expected, "「\(testCase.text)」\(testCase.note)")

            // 入库内容验证：.text 必须原样保存（不被百分号编码），.url 保持解析结果。
            let saved = store.savedEntries.last?.content
            switch testCase.expected {
            case .text:
                XCTAssertEqual(saved, .text(testCase.text), "「\(testCase.text)」必须原样保存为文本")
            case .url:
                guard case .url = saved else {
                    return XCTFail("「\(testCase.text)」应保存为 URL")
                }
            default:
                break
            }
        }
    }

    private func makeTextEntry(id: UUID, text: String) -> ClipboardEntry {
        ClipboardEntry(
            id: id,
            createdAt: Date(),
            type: .text,
            preview: text,
            sourceAppBundleID: nil,
            sourceAppName: nil,
            content: .text(text)
        )
    }
}

/// 可控 changeCount / 文本 / 图片 / 文件 URL 的 PasteboardClient 假件。
private final class FakeHistoryPasteboardClient: PasteboardClient {
    var changeCountValue = 0
    var text: String?
    var imageData: Data?
    var fileURLs: [URL] = []
    /// 模拟 org.nspasteboard.ConcealedType 标记（密码管理器声明的敏感内容）。
    var isConcealed = false
    /// 内容读取调用计数：验证 concealed 检查先于任何内容读取。
    private(set) var contentReadCount = 0

    var changeCount: Int { changeCountValue }

    func readFileURLs() -> [URL] {
        contentReadCount += 1
        return fileURLs
    }

    func readURL() -> URL? {
        contentReadCount += 1
        return nil
    }

    func readImageData() -> Data? {
        contentReadCount += 1
        return imageData
    }

    func readText() -> String? {
        contentReadCount += 1
        return text
    }

    func readRTFData() -> Data? {
        contentReadCount += 1
        return nil
    }
}

private final class FakeClipboardStore: ClipboardStore {
    private(set) var entries: [ClipboardEntry]
    private(set) var savedEntries: [ClipboardEntry] = []
    private(set) var deletedIDs: Set<UUID> = []
    private(set) var releaseMemoryCallCount = 0

    init(entries: [ClipboardEntry]) {
        self.entries = entries
    }

    func loadEntries() -> [ClipboardEntry] {
        entries
    }

    func saveEntries(_ entries: [ClipboardEntry]) {
        self.entries = entries
    }

    func saveEntry(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        savedEntries.append(entry)
    }

    func deleteEntries(ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        deletedIDs.formUnion(ids)
    }

    func loadFullContent(for entryID: UUID) -> ClipboardContent? {
        entries.first { $0.id == entryID }?.content
    }

    func releaseMemory() {
        releaseMemoryCallCount += 1
    }
}
