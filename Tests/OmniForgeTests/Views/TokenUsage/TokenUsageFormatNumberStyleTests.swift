import XCTest
@testable import OmniForge

/// 统计单位切换（2026-09-16）：compactTokens 西文 K/M/B 与中文 万/亿 两种风格的分档契约。
final class TokenUsageFormatNumberStyleTests: XCTestCase {

    // MARK: - 西文风格（缺省口径不变）

    func test_westernStyle_thresholds() {
        XCTAssertEqual(TokenUsageFormat.compactTokens(789, style: .western), "789")
        XCTAssertEqual(TokenUsageFormat.compactTokens(1500, style: .western), "1.5K")
        XCTAssertEqual(TokenUsageFormat.compactTokens(2_300_000, style: .western), "2.3M")
        XCTAssertEqual(TokenUsageFormat.compactTokens(8_800_000_000, style: .western), "8.8B")
    }

    /// 1 位小数去尾 `.0`（"1.0M" → "1M"）在西文风格下保持。
    func test_westernStyle_trailingZeroStripped() {
        XCTAssertEqual(TokenUsageFormat.compactTokens(1_000_000, style: .western), "1M")
        XCTAssertEqual(TokenUsageFormat.compactTokens(1_000, style: .western), "1K")
    }

    // MARK: - 中文风格（万 = 1e4 / 亿 = 1e8）

    /// 不足 1 万保持原样整数（不缩到千位）。
    func test_chineseStyle_belowWan_rawNumber() {
        XCTAssertEqual(TokenUsageFormat.compactTokens(789, style: .chinese), "789")
        XCTAssertEqual(TokenUsageFormat.compactTokens(1500, style: .chinese), "1500")
        XCTAssertEqual(TokenUsageFormat.compactTokens(9_999, style: .chinese), "9999")
    }

    func test_chineseStyle_wanTier() {
        XCTAssertEqual(TokenUsageFormat.compactTokens(10_000, style: .chinese), "1万")
        XCTAssertEqual(TokenUsageFormat.compactTokens(23_000, style: .chinese), "2.3万")
        XCTAssertEqual(TokenUsageFormat.compactTokens(1_000_000, style: .chinese), "100万")
        XCTAssertEqual(TokenUsageFormat.compactTokens(2_300_000, style: .chinese), "230万")
    }

    func test_chineseStyle_yiTier() {
        XCTAssertEqual(TokenUsageFormat.compactTokens(100_000_000, style: .chinese), "1亿")
        XCTAssertEqual(TokenUsageFormat.compactTokens(120_000_000, style: .chinese), "1.2亿")
        XCTAssertEqual(TokenUsageFormat.compactTokens(1_000_000_000, style: .chinese), "10亿")
        XCTAssertEqual(TokenUsageFormat.compactTokens(10_000_000_000, style: .chinese), "100亿")
    }

    /// 负数保留符号；万位进位走四舍五入（99999 → 10.0 万 → 去尾「10万」）。
    func test_chineseStyle_negativeAndRounding() {
        XCTAssertEqual(TokenUsageFormat.compactTokens(-23_000, style: .chinese), "-2.3万")
        XCTAssertEqual(TokenUsageFormat.compactTokens(99_999, style: .chinese), "10万")
    }

    // MARK: - 缺省参数兼容

    /// 缺省参数保持西文口径，既有调用（未显式传风格）行为不变。
    func test_defaultParameter_isWestern() {
        XCTAssertEqual(TokenUsageFormat.compactTokens(1500), "1.5K")
        XCTAssertEqual(TokenUsageFormat.compactTokens(2_300_000), "2.3M")
    }

    // MARK: - 枚举契约

    func test_numberStyle_caseOrderAndLabels() {
        // 切换器选项顺序锁定：西文在前（缺省）、中文在后；选项文案为符号本身。
        XCTAssertEqual(TokenUsageNumberStyle.allCases, [.western, .chinese])
        XCTAssertEqual(TokenUsageNumberStyle.western.label, "K / M / B")
        XCTAssertEqual(TokenUsageNumberStyle.chinese.label, "万 / 亿")
    }

    func test_numberStyle_codableRoundTrip() throws {
        for style in TokenUsageNumberStyle.allCases {
            let data = try JSONEncoder().encode(style)
            XCTAssertEqual(try JSONDecoder().decode(TokenUsageNumberStyle.self, from: data), style)
        }
    }
}
