import XCTest
@testable import OmniForge

/// Token 面板「余额 / 用量」分区（子 tab）行为测试。
final class TokenUsagePanelSectionTests: XCTestCase {
    func test_allCases_balanceFirstUsageSecond() {
        // 分段展示顺序由 CaseIterable 声明序驱动，锁定「余额在前、用量在后」
        XCTAssertEqual(TokenPanelSection.allCases, [.balance, .usage])
    }

    func test_sectionTitles_nonEmptyInBothLanguages() {
        for strings in [Strings.zhHans, Strings.en] {
            XCTAssertFalse(strings.tokenSectionBalance.isEmpty)
            XCTAssertFalse(strings.tokenSectionUsage.isEmpty)
            XCTAssertFalse(strings.tokenBalanceEmptyHint.isEmpty)
            for section in TokenPanelSection.allCases {
                XCTAssertFalse(section.title(strings).isEmpty, "\(section) 标签在两语言下均非空")
            }
        }
    }
}
