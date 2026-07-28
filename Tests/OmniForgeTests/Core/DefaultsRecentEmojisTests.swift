import XCTest
@testable import OmniForge

/// UserDefaults 读写契约 —— 用临时 suite 避免污染 .standard。
final class DefaultsRecentEmojisTests: XCTestCase {

    private var suiteName: String!
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "DefaultsRecentEmojisTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        suite = nil
        suiteName = nil
        super.tearDown()
    }

    func test_recentEmojis_missingKey_returnsEmpty() {
        suite.removeObject(forKey: UserDefaultsKeys.screenshotRecentEmojis)
        let result = Defaults.recentEmojis(in: suite)
        XCTAssertTrue(result.isEmpty,
                      "未写入过的键应返回空数组")
    }

    func test_setRecentEmojis_writesAndReads() {
        let emojis = ["🚀", "❤️", "🔥"]
        Defaults.setRecentEmojis(emojis, in: suite)
        let result = Defaults.recentEmojis(in: suite)
        XCTAssertEqual(result, emojis,
                       "写入后再读出应一致")
    }

    func test_setRecentEmojis_truncatesToLimit() {
        let many = (0..<15).map { _ in "✅" }
        Defaults.setRecentEmojis(many, limit: 10, in: suite)
        let result = Defaults.recentEmojis(in: suite)
        XCTAssertEqual(result.count, 10,
                       "超过限制后应截断到指定长度")
    }

    func test_setRecentEmojis_overwrites() {
        Defaults.setRecentEmojis(["🚀"], in: suite)
        Defaults.setRecentEmojis(["❤️"], in: suite)
        let result = Defaults.recentEmojis(in: suite)
        XCTAssertEqual(result, ["❤️"],
                       "第二次写入应覆盖上一次")
    }

    func test_setRecentEmojis_defaultLimit() {
        let many = (0..<20).map { _ in "🎉" }
        Defaults.setRecentEmojis(many, in: suite)
        let result = Defaults.recentEmojis(in: suite)
        XCTAssertEqual(result.count, 10,
                       "默认限制为 10")
    }
}
