import Combine
import Foundation
import GRDB

@MainActor
final class QuickPhraseManager: ObservableObject {
    @Published private(set) var phrases: [QuickPhraseEntry] = []
    /// 加载失败原因（非空 = 当前列表不可信，是空态之外的错误态）；
    /// 界面据此提示重试，不得伪装为空数据库后继续接受覆盖性写入。
    @Published private(set) var loadError: String?
    /// 最近一次写操作失败原因；nil = 无未决失败。失败时界面状态不前移，
    /// 编辑草稿由调用方保留并展示重试入口（审查 R19）。
    @Published private(set) var lastError: String?

    private let store: QuickPhraseStore

    init(store: QuickPhraseStore = makeDefaultStore()) {
        self.store = store
        loadPhrases()
    }

    private func loadPhrases() {
        do {
            phrases = try store.loadPhrases()
            loadError = nil
        } catch {
            phrases = []
            loadError = error.localizedDescription
        }
    }

    /// 重新加载（错误态重试入口）。
    func retryLoading() {
        loadPhrases()
    }

    /// 新增：写成功才提交界面状态。返回是否成功（失败保留草稿给调用方）。
    @discardableResult
    func add(content: String, group: String? = nil) -> Bool {
        let phrase = QuickPhraseEntry(content: content, group: group)
        do {
            try store.savePhrase(phrase)
            phrases.insert(phrase, at: 0)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// 更新：写成功才提交界面状态。
    @discardableResult
    func update(id: UUID, content: String, group: String? = nil) -> Bool {
        guard let index = phrases.firstIndex(where: { $0.id == id }) else { return false }
        var updated = phrases[index]
        updated.content = content
        updated.group = group
        updated.updatedAt = Date()
        do {
            try store.updatePhrase(updated)
            phrases[index] = updated
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// 删除：写成功才从界面移除（失败删除项仍在）。
    @discardableResult
    func delete(id: UUID) -> Bool {
        do {
            try store.deletePhrase(id: id)
            phrases.removeAll { $0.id == id }
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func releaseMemory() {
        store.releaseMemory()
    }

    func filtered(searchText: String, group: String?) -> [QuickPhraseEntry] {
        phrases.filter { phrase in
            let matchesSearch = searchText.isEmpty
                || phrase.content.localizedCaseInsensitiveContains(searchText)
                || (phrase.group?.localizedCaseInsensitiveContains(searchText) ?? false)
            let matchesGroup = group == nil || phrase.group == group
            return matchesSearch && matchesGroup
        }
    }

    func allGroups() -> [String] {
        Set(phrases.compactMap { $0.group }).sorted()
    }

    nonisolated static func makeDefaultStore() -> QuickPhraseStore {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("OmniForge/QuickPhrases")
        // 一次性迁移：老版本数据位于 `InputLock/QuickPhrases`，改名后搬迁到 `OmniForge/QuickPhrases`。
        let legacyDirectory = appSupport.appendingPathComponent("InputLock/QuickPhrases")
        LegacyDataMigrator.migrateDirectory(from: legacyDirectory, to: directory)
        let databaseURL = directory.appendingPathComponent("phrases.sqlite")
        return GRDBQuickPhraseStore(databaseURL: databaseURL)
    }
}
