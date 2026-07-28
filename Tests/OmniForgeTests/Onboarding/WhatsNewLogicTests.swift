import XCTest
@testable import OmniForge

final class WhatsNewLogicTests: XCTestCase {

    func test_whatsNewRelease_parsesVersion() {
        let release = WhatsNewRelease(version: "1.2.0", entries: [])
        XCTAssertEqual(release.version, "1.2.0")
    }

    func test_whatsNewRelease_entryTypes() {
        let entries: [WhatsNewEntry] = [
            WhatsNewEntry(type: .added, text: "新增功能 A"),
            WhatsNewEntry(type: .fixed, text: "修复问题 B"),
            WhatsNewEntry(type: .changed, text: "改进功能 C"),
        ]
        let release = WhatsNewRelease(version: "1.2.0", entries: entries)
        XCTAssertEqual(release.entries.count, 3)
        XCTAssertEqual(release.entries[0].type, .added)
        XCTAssertEqual(release.entries[1].type, .fixed)
        XCTAssertEqual(release.entries[2].type, .changed)
    }

    func test_whatsNewEntry_iconNames() {
        XCTAssertEqual(WhatsNewEntry.EntryType.added.iconName, "plus.circle.fill")
        XCTAssertEqual(WhatsNewEntry.EntryType.fixed.iconName, "checkmark.circle.fill")
        XCTAssertEqual(WhatsNewEntry.EntryType.changed.iconName, "slider.horizontal.3")
    }

    func test_currentReleaseEntries_notEmpty() {
        let entries = WhatsNewRelease.currentRelease.entries
        XCTAssertFalse(entries.isEmpty, "当前版本的 What's New 内容不应为空")
    }
}
