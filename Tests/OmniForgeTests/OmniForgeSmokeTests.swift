//
//  OmniForgeSmokeTests.swift
//  OmniForgeTests
//
//  Created by 苏御 on 2026/1/27.
//

import Carbon
import XCTest
@testable import OmniForge

final class OmniForgeSmokeTests: XCTestCase {
    func test_smoke() {
        XCTAssertTrue(true)
    }
}

@MainActor
final class ClipboardHistoryRowActionHandlerTests: XCTestCase {
    func test_singleClickSelectsEntry() {
        let entry = makeEntry()
        var selectedID: UUID?
        var pastedEntry: ClipboardEntry?
        let handler = ClipboardHistoryRowActionHandler(
            select: { selectedID = $0 },
            paste: { pastedEntry = $0 }
        )

        handler.handleClick(entry: entry, clickCount: 1)

        XCTAssertEqual(selectedID, entry.id)
        XCTAssertNil(pastedEntry)
    }

    func test_doubleClickPastesEntry() {
        let entry = makeEntry()
        var selectedID: UUID?
        var pastedEntry: ClipboardEntry?
        let handler = ClipboardHistoryRowActionHandler(
            select: { selectedID = $0 },
            paste: { pastedEntry = $0 }
        )

        handler.handleClick(entry: entry, clickCount: 2)

        XCTAssertNil(selectedID)
        XCTAssertEqual(pastedEntry, entry)
    }
}

@MainActor
final class ClipboardHistoryKeyHandlerTests: XCTestCase {
    func test_upArrowMovesSelection() {
        var moveDirection: Int?
        var didPaste = false
        let handler = ClipboardHistoryKeyHandler(
            moveSelection: { moveDirection = $0 },
            paste: { didPaste = true }
        )

        let handled = handler.handleKeyDown(keyCode: UInt16(kVK_UpArrow))

        XCTAssertTrue(handled)
        XCTAssertEqual(moveDirection, -1)
        XCTAssertFalse(didPaste)
    }

    func test_returnPastes() {
        var moveDirection: Int?
        var didPaste = false
        let handler = ClipboardHistoryKeyHandler(
            moveSelection: { moveDirection = $0 },
            paste: { didPaste = true }
        )

        let handled = handler.handleKeyDown(keyCode: UInt16(kVK_Return))

        XCTAssertTrue(handled)
        XCTAssertNil(moveDirection)
        XCTAssertTrue(didPaste)
    }

    func test_scrollAnchorPlacesSelectionAtEdge() {
        XCTAssertEqual(ClipboardHistoryKeyHandler.scrollAnchor(forMoveDirection: 1), .bottom)
        XCTAssertEqual(ClipboardHistoryKeyHandler.scrollAnchor(forMoveDirection: -1), .top)
    }
}

final class ClipboardHistoryScrollDeciderTests: XCTestCase {
    func test_shouldScrollOnlyWhenSelectionNotVisible() {
        let selected = UUID()
        XCTAssertFalse(ClipboardHistoryScrollDecider.shouldScroll(selectedID: selected, visibleIDs: Set()))
        XCTAssertFalse(ClipboardHistoryScrollDecider.shouldScroll(selectedID: selected, visibleIDs: Set([selected])))
        XCTAssertTrue(ClipboardHistoryScrollDecider.shouldScroll(selectedID: selected, visibleIDs: Set([UUID()])))
    }
}

final class ClipboardHistoryScrollPlannerTests: XCTestCase {
    func test_plansNoAnchorWhenOldSelectionMissing() {
        let entries = makeEntries()
        let planned = ClipboardHistoryScrollPlanner.plannedAnchor(
            oldSelectedID: nil,
            newSelectedID: entries[1].id,
            entries: entries
        )

        XCTAssertNil(planned)
    }

    func test_plansBottomAnchorWhenMovingDown() {
        let entries = makeEntries()
        let planned = ClipboardHistoryScrollPlanner.plannedAnchor(
            oldSelectedID: entries[0].id,
            newSelectedID: entries[2].id,
            entries: entries
        )

        XCTAssertEqual(planned, .bottom)
    }

    func test_plansTopAnchorWhenMovingUp() {
        let entries = makeEntries()
        let planned = ClipboardHistoryScrollPlanner.plannedAnchor(
            oldSelectedID: entries[2].id,
            newSelectedID: entries[0].id,
            entries: entries
        )

        XCTAssertEqual(planned, .top)
    }
}

final class ThinScrollIndicatorVisibilityTrackerTests: XCTestCase {
    func test_showRequestOnlyFirstTimeReturnsTrue() {
        var tracker = ThinScrollIndicatorVisibilityTracker()

        XCTAssertTrue(tracker.requestShow())
        XCTAssertFalse(tracker.requestShow())
    }

    func test_hideRequestOnlyWhenVisibleReturnsTrue() {
        var tracker = ThinScrollIndicatorVisibilityTracker()

        XCTAssertFalse(tracker.requestHide())
        XCTAssertTrue(tracker.requestShow())
        XCTAssertTrue(tracker.requestHide())
        XCTAssertFalse(tracker.requestHide())
    }
}

private func makeEntry() -> ClipboardEntry {
    ClipboardEntry(
        id: UUID(),
        createdAt: Date(),
        type: .text,
        preview: "Preview",
        sourceAppBundleID: "com.example.app",
        sourceAppName: "Example",
        content: .text("Preview")
    )
}

private func makeEntries() -> [ClipboardEntry] {
    [
        makeEntry(),
        makeEntry(),
        makeEntry()
    ]
}
