import XCTest
@testable import OmniForge

/// 固定 AppUninstaller 的安全规则 —— 这些保证扫描结果绝不含路径穿越、嵌套重复或越界路径。
final class AppUninstallerSafetyTests: XCTestCase {

    private let bundleID = "com.maker.editor"

    // MARK: matchesBundleScopedName

    func test_matchesBundleScopedName_exactMatch() {
        XCTAssertTrue(AppUninstaller.matchesBundleScopedName(bundleID, bundleID: bundleID))
    }

    func test_matchesBundleScopedName_prefixChild() {
        XCTAssertTrue(AppUninstaller.matchesBundleScopedName("com.maker.editor.helper", bundleID: bundleID))
    }

    func test_matchesBundleScopedName_suffixParent() {
        XCTAssertTrue(AppUninstaller.matchesBundleScopedName("group.com.maker.editor", bundleID: bundleID))
    }

    func test_matchesBundleScopedName_middleContained() {
        XCTAssertTrue(AppUninstaller.matchesBundleScopedName("systemgroup.com.maker.editor.cache", bundleID: bundleID))
    }

    func test_matchesBundleScopedName_unrelatedReturnsFalse() {
        XCTAssertFalse(AppUninstaller.matchesBundleScopedName("com.other.app", bundleID: bundleID))
        // 仅前缀字符串相同但非点边界 —— com.maker.editorX 不应匹配
        XCTAssertFalse(AppUninstaller.matchesBundleScopedName("com.maker.editorX", bundleID: bundleID))
    }

    // MARK: dedupe

    func test_dedupe_removesExactDuplicates() {
        let url = URL(fileURLWithPath: "/tmp/abc")
        let input = [(url, AppUninstaller.Category.support),
                     (url, AppUninstaller.Category.support)]
        let result = AppUninstaller.dedupe(input)
        XCTAssertEqual(result.count, 1)
    }

    func test_dedupe_dropsNestedPaths() {
        // 父目录在前 → 子目录应被丢弃
        let parent = URL(fileURLWithPath: "/tmp/app")
        let child = URL(fileURLWithPath: "/tmp/app/inner")
        let input = [(parent, AppUninstaller.Category.support),
                     (child, AppUninstaller.Category.support)]
        let result = AppUninstaller.dedupe(input)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.0, parent)
    }

    func test_dedupe_keepsSiblings() {
        let a = URL(fileURLWithPath: "/tmp/appA")
        let b = URL(fileURLWithPath: "/tmp/appB")
        let input = [(a, AppUninstaller.Category.support),
                     (b, AppUninstaller.Category.caches)]
        let result = AppUninstaller.dedupe(input)
        XCTAssertEqual(result.count, 2)
    }

    func test_dedupe_childFirstStillDedupesAgainstLaterParent() {
        // 顺序无关：子目录在前、父目录在后，子也应被父吸收
        let parent = URL(fileURLWithPath: "/tmp/app")
        let child = URL(fileURLWithPath: "/tmp/app/inner")
        let input = [(child, AppUninstaller.Category.support),
                     (parent, AppUninstaller.Category.support)]
        let result = AppUninstaller.dedupe(input)
        XCTAssertEqual(result.count, 1, "无论输入顺序，嵌套子路径都应被父吸收")
    }
}
