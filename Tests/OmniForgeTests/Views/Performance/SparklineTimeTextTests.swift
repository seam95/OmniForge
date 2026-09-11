import XCTest
@testable import OmniForge

/// 折线悬浮气泡时间文本格式 — HH:mm:ss 本地时区
final class SparklineTimeTextTests: XCTestCase {
    func test_time_usesHHmmssFormat() {
        let text = SparklineTimeText.time(Date())
        XCTAssertNotNil(text.range(of: #"^\d{2}:\d{2}:\d{2}$"#, options: .regularExpression))
    }

    func test_time_roundTripsThroughCalendarComponents() {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 5
        components.hour = 14
        components.minute = 32
        components.second = 5
        let date = Calendar.current.date(from: components)!

        let text = SparklineTimeText.time(date)
        XCTAssertEqual(text, "14:32:05")
    }
}
