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

/// 可控 changeCount / 文本的 PasteboardClient 假件（驱动 pollPasteboard 采集分支）。
private final class FakeHistoryPasteboardClient: PasteboardClient {
    var changeCountValue = 0
    var text: String?

    var changeCount: Int { changeCountValue }

    func readFileURLs() -> [URL] { [] }
    func readURL() -> URL? { nil }
    func readImageData() -> Data? { nil }
    func readText() -> String? { text }
    func readRTFData() -> Data? { nil }
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
