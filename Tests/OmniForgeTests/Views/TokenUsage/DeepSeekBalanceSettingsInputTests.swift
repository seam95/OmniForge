import Foundation
import XCTest
@testable import OmniForge

/// DeepSeek 余额设置输入校验：Key 清洗与阈值解析（仅正有限数）。
final class DeepSeekBalanceSettingsInputTests: XCTestCase {
    // MARK: - API Key 清洗

    func test_validation_sanitizeAPIKeyTrims() {
        XCTAssertEqual(DeepSeekSettingsValidation.sanitizedAPIKey("  sk-abc  "), "sk-abc")
        XCTAssertEqual(DeepSeekSettingsValidation.sanitizedAPIKey("sk-abc"), "sk-abc")
        XCTAssertEqual(DeepSeekSettingsValidation.sanitizedAPIKey("   "), "")
    }

    // MARK: - 阈值解析

    func test_validation_parseThresholdPositiveOnly() {
        XCTAssertEqual(DeepSeekSettingsValidation.parseThreshold("1"), 1.0)
        XCTAssertEqual(DeepSeekSettingsValidation.parseThreshold(" 2.5 "), 2.5)
        XCTAssertNil(DeepSeekSettingsValidation.parseThreshold("0"))
        XCTAssertNil(DeepSeekSettingsValidation.parseThreshold("-1"))
        XCTAssertNil(DeepSeekSettingsValidation.parseThreshold(""))
        XCTAssertNil(DeepSeekSettingsValidation.parseThreshold("abc"))
        XCTAssertNil(DeepSeekSettingsValidation.parseThreshold("inf"))
        XCTAssertNil(DeepSeekSettingsValidation.parseThreshold("nan"))
    }
}
