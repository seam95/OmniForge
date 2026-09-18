import XCTest
@testable import OmniForge

/// 外部时间戳清洗：上游 JSONL/API 坏数据（NaN/Inf/超大值）不得使 Int(Double) trap。
final class UsageTimestampSanitizerTests: XCTestCase {
    func test_epochSeconds_acceptsNormalValues() {
        XCTAssertEqual(UsageTimestampSanitizer.epochSeconds(1_784_357_100.5), 1_784_357_100)
        XCTAssertEqual(UsageTimestampSanitizer.epochSeconds(fromMilliseconds: 1_784_357_100_000), 1_784_357_100)
    }

    func test_epochSeconds_rejectsNonFiniteAndNonPositive() {
        XCTAssertNil(UsageTimestampSanitizer.epochSeconds(.nan))
        XCTAssertNil(UsageTimestampSanitizer.epochSeconds(.infinity))
        XCTAssertNil(UsageTimestampSanitizer.epochSeconds(0))
        XCTAssertNil(UsageTimestampSanitizer.epochSeconds(-100))
        XCTAssertNil(UsageTimestampSanitizer.epochSeconds(fromMilliseconds: .nan))
        XCTAssertNil(UsageTimestampSanitizer.epochSeconds(fromMilliseconds: 0))
    }

    func test_epochSeconds_rejectsOutOfRangeMagnitudes() {
        // 超出 Int64 表示范围的有限值与荒谬未来时间（毫秒误传秒位）都拒绝，
        // 此前这两类值会直接 fatal error 崩掉整个应用。
        XCTAssertNil(UsageTimestampSanitizer.epochSeconds(1e300))
        XCTAssertNil(UsageTimestampSanitizer.epochSeconds(fromMilliseconds: 1e300))
        XCTAssertNil(UsageTimestampSanitizer.epochSeconds(9_999_999_999_999))
    }
}
