import XCTest
@testable import OmniForge

@MainActor
final class QuickPhraseManagerTests: XCTestCase {
    // MARK: - 存储失败可见（审查 R19）

    /// 写失败：界面状态不前移（不显示成功）、错误可见。
    func test_addWriteFailure_keepsUIUnchangedAndExposesError() {
        let store = InMemoryQuickPhraseStore()
        store.writeError = QuickPhraseStoreStubError.writeFailed
        let manager = QuickPhraseManager(store: store)

        let added = manager.add(content: "Draft", group: nil)

        XCTAssertFalse(added, "写失败必须返回 false")
        XCTAssertTrue(manager.phrases.isEmpty, "失败不提交界面状态")
        XCTAssertNotNil(manager.lastError, "错误必须可见")
    }

    /// 更新失败：原内容保留在界面，不显示更新成功。
    func test_updateWriteFailure_keepsOriginalContent() {
        let store = InMemoryQuickPhraseStore()
        let manager = QuickPhraseManager(store: store)
        manager.add(content: "Original", group: nil)
        let id = manager.phrases.first!.id

        store.writeError = QuickPhraseStoreStubError.writeFailed
        let updated = manager.update(id: id, content: "Changed", group: nil)

        XCTAssertFalse(updated)
        XCTAssertEqual(manager.phrases.first?.content, "Original", "失败不改界面")
        XCTAssertNotNil(manager.lastError)
    }

    /// 删除失败：条目仍在列表。
    func test_deleteWriteFailure_keepsEntryInList() {
        let store = InMemoryQuickPhraseStore()
        let manager = QuickPhraseManager(store: store)
        manager.add(content: "Keep", group: nil)
        let id = manager.phrases.first!.id

        store.writeError = QuickPhraseStoreStubError.writeFailed
        let deleted = manager.delete(id: id)

        XCTAssertFalse(deleted)
        XCTAssertEqual(manager.phrases.count, 1, "失败删除项仍在")
    }

    /// 加载失败：暴露错误态而非伪装空库；恢复后重试加载成功。
    func test_loadFailure_exposesErrorAndRetryRecovers() {
        let store = InMemoryQuickPhraseStore()
        try? store.savePhrase(QuickPhraseEntry(content: "Persisted", group: nil))
        store.loadError = QuickPhraseStoreStubError.loadFailed
        let manager = QuickPhraseManager(store: store)

        XCTAssertTrue(manager.phrases.isEmpty)
        XCTAssertNotNil(manager.loadError, "加载失败不得伪装为空数据库")

        store.loadError = nil
        manager.retryLoading()
        XCTAssertEqual(manager.phrases.first?.content, "Persisted")
        XCTAssertNil(manager.loadError)
    }

    private enum QuickPhraseStoreStubError: Error {
        case writeFailed
        case loadFailed
    }

    func test_addPhrase_insertsAtBeginning() {
        let store = InMemoryQuickPhraseStore()
        let manager = QuickPhraseManager(store: store)

        manager.add(content: "First phrase", group: "Work")

        XCTAssertEqual(manager.phrases.count, 1)
        XCTAssertEqual(manager.phrases.first?.content, "First phrase")
    }

    func test_addPhrase_withGroup() {
        let store = InMemoryQuickPhraseStore()
        let manager = QuickPhraseManager(store: store)

        manager.add(content: "Test", group: "Personal")

        XCTAssertEqual(manager.phrases.first?.group, "Personal")
    }

    func test_deletePhrase_removesFromList() {
        let store = InMemoryQuickPhraseStore()
        let manager = QuickPhraseManager(store: store)

        manager.add(content: "To delete", group: nil)
        let id = manager.phrases.first!.id

        manager.delete(id: id)

        XCTAssertEqual(manager.phrases.count, 0)
    }

    func test_filtered_bySearchText() {
        let store = InMemoryQuickPhraseStore()
        let manager = QuickPhraseManager(store: store)

        manager.add(content: "Hello World", group: nil)
        manager.add(content: "Goodbye", group: nil)

        let results = manager.filtered(searchText: "hello", group: nil)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.content, "Hello World")
    }

    func test_filtered_byGroup() {
        let store = InMemoryQuickPhraseStore()
        let manager = QuickPhraseManager(store: store)

        manager.add(content: "Work item", group: "Work")
        manager.add(content: "Personal note", group: "Personal")

        let results = manager.filtered(searchText: "", group: "Work")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.group, "Work")
    }

    func test_allGroups_returnsUniqueSortedGroups() {
        let store = InMemoryQuickPhraseStore()
        let manager = QuickPhraseManager(store: store)

        manager.add(content: "A", group: "Z")
        manager.add(content: "B", group: "A")
        manager.add(content: "C", group: "A")
        manager.add(content: "D", group: nil)

        let groups = manager.allGroups()

        XCTAssertEqual(groups, ["A", "Z"])
    }

    func test_releaseMemory_forwardsToStore() {
        let store = InMemoryQuickPhraseStore()
        let manager = QuickPhraseManager(store: store)

        manager.releaseMemory()

        XCTAssertEqual(store.releaseMemoryCallCount, 1)
    }
}

private final class InMemoryQuickPhraseStore: QuickPhraseStore {
    private var phrases: [QuickPhraseEntry] = []
    private(set) var releaseMemoryCallCount = 0

    /// 置非 nil 时对应操作抛错（失败路径注入）。
    var loadError: Error?
    var writeError: Error?

    func loadPhrases() throws -> [QuickPhraseEntry] {
        if let loadError {
            throw loadError
        }
        return phrases
    }

    func savePhrase(_ phrase: QuickPhraseEntry) throws {
        if let writeError {
            throw writeError
        }
        phrases.append(phrase)
    }

    func deletePhrase(id: UUID) throws {
        if let writeError {
            throw writeError
        }
        phrases.removeAll { $0.id == id }
    }

    func updatePhrase(_ phrase: QuickPhraseEntry) throws {
        if let writeError {
            throw writeError
        }
        if let index = phrases.firstIndex(where: { $0.id == phrase.id }) {
            phrases[index] = phrase
        }
    }

    func releaseMemory() {
        releaseMemoryCallCount += 1
    }
}
