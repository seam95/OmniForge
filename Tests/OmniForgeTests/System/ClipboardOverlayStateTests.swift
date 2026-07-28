import XCTest
@testable import OmniForge

@MainActor
final class ClipboardOverlayStateTests: XCTestCase {
    func test_moveSelectionMovesUpAndDown() {
        let entries = makeEntries()
        let state = ClipboardOverlayState()
        state.selectedEntryID = entries[0].id

        state.moveSelection(in: entries, direction: 1)
        XCTAssertEqual(state.selectedEntryID, entries[1].id)

        state.moveSelection(in: entries, direction: -1)
        XCTAssertEqual(state.selectedEntryID, entries[0].id)
    }

    func test_moveSelectionDefaultsToFirstWhenSelectionMissing() {
        let entries = makeEntries()
        let state = ClipboardOverlayState()
        state.selectedEntryID = UUID()

        state.moveSelection(in: entries, direction: 1)
        XCTAssertEqual(state.selectedEntryID, entries[0].id)
    }

    func test_moveSelectionWithEmptyEntriesClearsSelection() {
        let state = ClipboardOverlayState()
        state.selectedEntryID = UUID()

        state.moveSelection(in: [], direction: 1)
        XCTAssertNil(state.selectedEntryID)
    }

    func test_resetForNewSessionClearsTransientState() {
        let state = ClipboardOverlayState()
        state.searchText = "hello"
        state.filter = .image
        state.selectedEntryID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")

        state.resetForNewSession()

        XCTAssertEqual(state.searchText, "")
        XCTAssertEqual(state.filter, .all)
        XCTAssertNil(state.selectedEntryID)
    }

    func test_resetForNewSessionIncrementsSessionResetToken() {
        let state = ClipboardOverlayState()
        let oldToken = state.sessionResetToken

        state.resetForNewSession()

        XCTAssertEqual(state.sessionResetToken, oldToken + 1)
    }

    private func makeEntries() -> [ClipboardEntry] {
        [
            ClipboardEntry(id: UUID(), createdAt: Date(), type: .text, preview: "1", sourceAppBundleID: nil, sourceAppName: nil, content: .text("1")),
            ClipboardEntry(id: UUID(), createdAt: Date(), type: .text, preview: "2", sourceAppBundleID: nil, sourceAppName: nil, content: .text("2")),
            ClipboardEntry(id: UUID(), createdAt: Date(), type: .text, preview: "3", sourceAppBundleID: nil, sourceAppName: nil, content: .text("3"))
        ]
    }
}
