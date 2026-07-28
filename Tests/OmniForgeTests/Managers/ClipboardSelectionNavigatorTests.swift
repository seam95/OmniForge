import XCTest
@testable import OmniForge

final class ClipboardSelectionNavigatorTests: XCTestCase {
    func test_movesSelectionUpAndDown() {
        let entries = makeEntries()
        let next = ClipboardSelectionNavigator.nextSelection(in: entries, currentID: entries[0].id, direction: 1)
        let previous = ClipboardSelectionNavigator.nextSelection(in: entries, currentID: entries[1].id, direction: -1)

        XCTAssertEqual(next, entries[1].id)
        XCTAssertEqual(previous, entries[0].id)
    }

    func test_defaultsToFirstWhenSelectionMissing() {
        let entries = makeEntries()
        let result = ClipboardSelectionNavigator.nextSelection(in: entries, currentID: UUID(), direction: 1)

        XCTAssertEqual(result, entries[0].id)
    }

    private func makeEntries() -> [ClipboardEntry] {
        [
            ClipboardEntry(id: UUID(), createdAt: Date(), type: .text, preview: "1", sourceAppBundleID: nil, sourceAppName: nil, content: .text("1")),
            ClipboardEntry(id: UUID(), createdAt: Date(), type: .text, preview: "2", sourceAppBundleID: nil, sourceAppName: nil, content: .text("2")),
            ClipboardEntry(id: UUID(), createdAt: Date(), type: .text, preview: "3", sourceAppBundleID: nil, sourceAppName: nil, content: .text("3"))
        ]
    }
}
