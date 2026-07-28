import Combine
import Foundation
import GRDB

@MainActor
final class QuickPhraseManager: ObservableObject {
    @Published private(set) var phrases: [QuickPhraseEntry] = []

    private let store: QuickPhraseStore

    init(store: QuickPhraseStore = makeDefaultStore()) {
        self.store = store
        loadPhrases()
    }

    private func loadPhrases() {
        phrases = store.loadPhrases()
    }

    func add(content: String, group: String? = nil) {
        let phrase = QuickPhraseEntry(content: content, group: group)
        store.savePhrase(phrase)
        phrases.insert(phrase, at: 0)
    }

    func update(id: UUID, content: String, group: String? = nil) {
        guard let index = phrases.firstIndex(where: { $0.id == id }) else { return }
        var updated = phrases[index]
        updated.content = content
        updated.group = group
        updated.updatedAt = Date()
        store.updatePhrase(updated)
        phrases[index] = updated
    }

    func delete(id: UUID) {
        store.deletePhrase(id: id)
        phrases.removeAll { $0.id == id }
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
