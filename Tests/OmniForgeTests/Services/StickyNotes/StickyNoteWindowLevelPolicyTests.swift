import AppKit
import XCTest
@testable import OmniForge

/// 便签窗口层级策略契约：置顶与「选中态临时抬升」两个维度的裁决。
@MainActor
final class StickyNoteWindowLevelPolicyTests: XCTestCase {
    func test_level_pinnedIsFloatingRegardlessOfSelection() {
        XCTAssertEqual(
            StickyNoteWindowLevelPolicy.level(pinned: true, selectionPromoted: false),
            .floating
        )
        XCTAssertEqual(
            StickyNoteWindowLevelPolicy.level(pinned: true, selectionPromoted: true),
            .floating,
            "置顶便签的层级不受选中态影响"
        )
    }

    func test_level_unpinnedSelectedIsOneLevelAboveNormal() {
        XCTAssertEqual(
            StickyNoteWindowLevelPolicy.level(pinned: false, selectionPromoted: true),
            StickyNoteWindowLevelPolicy.selectionPromotedLevel
        )
        XCTAssertEqual(
            StickyNoteWindowLevelPolicy.selectionPromotedLevel,
            NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        )
    }

    func test_level_unpinnedIdleStaysNormal() {
        XCTAssertEqual(
            StickyNoteWindowLevelPolicy.level(pinned: false, selectionPromoted: false),
            .normal
        )
    }

    func test_selectionPromotedLevelSitsBetweenNormalAndFloating() {
        XCTAssertGreaterThan(
            StickyNoteWindowLevelPolicy.selectionPromotedLevel.rawValue,
            NSWindow.Level.normal.rawValue,
            "选中态必须压过普通窗口"
        )
        XCTAssertLessThan(
            StickyNoteWindowLevelPolicy.selectionPromotedLevel.rawValue,
            NSWindow.Level.floating.rawValue,
            "选中态不得越过浮动层级，避免与置顶语义混同"
        )
    }

    func test_collectionBehavior_pinnedJoinsAllSpaces() {
        let behavior = StickyNoteWindowLevelPolicy.collectionBehavior(pinned: true)

        XCTAssertTrue(behavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(behavior.contains(.ignoresCycle))
    }

    func test_collectionBehavior_unpinnedStaysOnCurrentSpace() {
        let behavior = StickyNoteWindowLevelPolicy.collectionBehavior(pinned: false)

        XCTAssertFalse(
            behavior.contains(.canJoinAllSpaces),
            "选中态不得跨 Space：跨 Space 会变成事实置顶"
        )
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(behavior.contains(.ignoresCycle))
    }
}
