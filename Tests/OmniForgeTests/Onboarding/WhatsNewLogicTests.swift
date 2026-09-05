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

    func test_catalog_firstReleaseEntries_notEmpty() {
        let entries = WhatsNewReleaseCatalog.releases.first?.entries ?? []
        XCTAssertFalse(entries.isEmpty, "目录最新一组的 What's New 内容不应为空")
    }

    func test_catalog_releases_areDescending() {
        let releases = WhatsNewReleaseCatalog.releases
        guard releases.count >= 2 else { return }
        for (newer, older) in zip(releases, releases.dropFirst()) {
            XCTAssertTrue(
                WhatsNewReleaseCatalog.compareVersions(newer.version, older.version) > 0,
                "目录必须新版本在前（\(newer.version) 应晚于 \(older.version)）"
            )
        }
    }

    // MARK: - 版本比较

    func test_compareVersions_equalWithDifferentSegmentCount() {
        XCTAssertEqual(WhatsNewReleaseCatalog.compareVersions("3.4", "3.4.0"), 0)
        XCTAssertEqual(WhatsNewReleaseCatalog.compareVersions("3.4", "3.4"), 0)
    }

    func test_compareVersions_numericNotLexicographic() {
        XCTAssertGreaterThan(WhatsNewReleaseCatalog.compareVersions("3.10", "3.9"), 0)
        XCTAssertLessThan(WhatsNewReleaseCatalog.compareVersions("3.9", "3.10"), 0)
    }

    func test_compareVersions_prefixSegmentWins() {
        XCTAssertGreaterThan(WhatsNewReleaseCatalog.compareVersions("3.4.1", "3.4"), 0)
        XCTAssertLessThan(WhatsNewReleaseCatalog.compareVersions("3.4", "3.5"), 0)
    }

    // MARK: - 展示范围（注入固定目录验证过滤语义，不依赖真实目录规模）

    private func makeCatalog(_ versions: [String]) -> [WhatsNewRelease] {
        versions.map { WhatsNewRelease(version: $0, entries: []) }
    }

    func test_releases_after_middleVersion_returnsOnlyNewer() {
        let catalog = makeCatalog(["3.5", "3.4", "3.3"])
        let result = WhatsNewReleaseCatalog.releases(after: "3.3", in: catalog)
        XCTAssertEqual(result.map(\.version), ["3.5", "3.4"])
    }

    func test_releases_afterLatest_fallsBackToLatest() {
        let catalog = makeCatalog(["3.5", "3.4"])
        let result = WhatsNewReleaseCatalog.releases(after: "3.5", in: catalog)
        XCTAssertEqual(result.map(\.version), ["3.5"], "无更新记录时应回退最新一组，避免空窗")
    }

    func test_releases_afterUnrecordedHigherVersion_fallsBackToLatest() {
        // 用户本地版本比目录还新（目录漏维护）时同样回退，不弹空窗
        let catalog = makeCatalog(["3.4"])
        let result = WhatsNewReleaseCatalog.releases(after: "99.0", in: catalog)
        XCTAssertEqual(result.map(\.version), ["3.4"])
    }

    func test_releases_afterNilOrEmpty_returnsAll() {
        let catalog = makeCatalog(["3.5", "3.4"])
        XCTAssertEqual(WhatsNewReleaseCatalog.releases(after: nil, in: catalog).count, 2)
        XCTAssertEqual(WhatsNewReleaseCatalog.releases(after: "", in: catalog).count, 2)
    }
}
