import XCTest
@testable import OmniForge

@MainActor
final class QuickPhraseManagerTests: XCTestCase {
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

    func loadPhrases() -> [QuickPhraseEntry] {
        phrases
    }

    func savePhrase(_ phrase: QuickPhraseEntry) {
        phrases.append(phrase)
    }

    func deletePhrase(id: UUID) {
        phrases.removeAll { $0.id == id }
    }

    func updatePhrase(_ phrase: QuickPhraseEntry) {
        if let index = phrases.firstIndex(where: { $0.id == phrase.id }) {
            phrases[index] = phrase
        }
    }

    func releaseMemory() {
        releaseMemoryCallCount += 1
    }
}
