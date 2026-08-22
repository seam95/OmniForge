import XCTest
@testable import OmniForge

/// 「按 Provider」分布行的行态纯逻辑（#09）：无数据右值灰显 `--`、Cursor 行标「云端口径」。
/// 纯符号 `--` 无需本地化（约束第 5 条）；徽标文案走 `strings.tokenCloudBadge`。
final class TokenUsageDistributionRowStateTests: XCTestCase {

    func test_distributionValue_nilDisplaysDash() {
        let entry = UsageDistributionEntry(label: "Cursor", totalTokens: nil, provider: .cursor)
        XCTAssertEqual(TokenUsageFormat.distributionValue(entry), "--", "无数值右值灰显 `--`（纯符号）")
    }

    func test_distributionValue_dataDisplaysAbbreviatedTokens() {
        let entry = UsageDistributionEntry(label: "Cursor", totalTokens: 128_400, provider: .cursor)
        XCTAssertEqual(TokenUsageFormat.distributionValue(entry), "128.4k")
    }

    func test_showsCloudScopeBadge_trueOnlyForCursorRows() {
        XCTAssertTrue(TokenUsageFormat.showsCloudScopeBadge(
            for: UsageDistributionEntry(label: "Cursor", totalTokens: 10, provider: .cursor)
        ))
        XCTAssertFalse(TokenUsageFormat.showsCloudScopeBadge(
            for: UsageDistributionEntry(label: "Claude", totalTokens: 10, provider: .claude)
        ))
        XCTAssertFalse(TokenUsageFormat.showsCloudScopeBadge(
            for: UsageDistributionEntry(label: "opus", totalTokens: 10, provider: nil)
        ), "按模型区不出现云端口径徽标")
    }
}
