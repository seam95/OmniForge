import XCTest
@testable import OmniForge

final class UsageWindowParsingTests: XCTestCase {
    func test_clampPercent() {
        XCTAssertEqual(UsageWindowParsing.clampPercent(82), 82)
        XCTAssertEqual(UsageWindowParsing.clampPercent(-5), 0)
        XCTAssertEqual(UsageWindowParsing.clampPercent(120), 100)
        XCTAssertNil(UsageWindowParsing.clampPercent(nil))
        XCTAssertNil(UsageWindowParsing.clampPercent(.nan))
        XCTAssertNil(UsageWindowParsing.clampPercent(.infinity))
    }

    func test_parseResetDate_unixSeconds() {
        let date = UsageWindowParsing.parseResetDate(1_755_000_000)
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_755_000_000))
    }

    func test_parseResetDate_unixMilliseconds() {
        let date = UsageWindowParsing.parseResetDate(1_755_000_000_000)
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_755_000_000))
    }

    func test_parseResetDate_isoString() {
        let string = "2026-08-22T13:30:00Z"
        let date = UsageWindowParsing.parseResetDate(string)
        XCTAssertNotNil(date)
    }

    func test_parseResetDate_numericString() {
        let date = UsageWindowParsing.parseResetDate("1755000000")
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_755_000_000))
    }

    func test_parseResetDate_invalidReturnsNil() {
        XCTAssertNil(UsageWindowParsing.parseResetDate(nil))
        XCTAssertNil(UsageWindowParsing.parseResetDate("not-a-date"))
        XCTAssertNil(UsageWindowParsing.parseResetDate(-1))
    }

    func test_windowKind_bySeconds() {
        XCTAssertEqual(UsageWindowParsing.windowKind(forSeconds: 18000), .session)
        XCTAssertEqual(UsageWindowParsing.windowKind(forSeconds: 604800), .weekly)
        XCTAssertNil(UsageWindowParsing.windowKind(forSeconds: 2592000))
    }

    func test_makeWindow_normalizesPercentAndKind() {
        let raw: [String: Any] = [
            "used_percent": 82,
            "reset_at": 1_755_000_000,
            "limit_window_seconds": 18000,
        ]
        let window = UsageWindowParsing.makeWindow(from: raw)
        XCTAssertEqual(window.usedPercent, 82)
        XCTAssertEqual(window.resetAt, Date(timeIntervalSince1970: 1_755_000_000))
        XCTAssertEqual(window.windowSeconds, 18000)
        XCTAssertEqual(UsageWindowParsing.windowKind(forSeconds: window.windowSeconds ?? 0), .session)
    }

    func test_makeWindow_creditsBackfillsPercentFromLimitUsed() {
        let raw: [String: Any] = [
            "limit": 50,
            "used": 12.5,
            "unit": "credits",
        ]
        let window = UsageWindowParsing.makeWindow(from: raw)
        XCTAssertEqual(window.usedPercent, 25, accuracy: 0.001)
        XCTAssertEqual(window.limit, 50)
        XCTAssertEqual(window.used, 12.5)
        XCTAssertEqual(window.unit, "credits")
        XCTAssertNil(window.resetAt)
    }

    func test_makeWindow_parsesNumericStrings() {
        let raw: [String: Any] = [
            "used_percent": "45",
            "limit": "10.0",
            "used": "2.25",
        ]
        let window = UsageWindowParsing.makeWindow(from: raw)
        XCTAssertEqual(window.usedPercent, 45)
        XCTAssertEqual(window.limit, 10)
        XCTAssertEqual(window.used, 2.25)
    }

    func test_makeWindow_creditsRemainingKept() {
        let raw: [String: Any] = [
            "used_percent": 70,
            "remaining": 2.10,
            "limit": 7,
            "unit": "USD",
        ]
        let window = UsageWindowParsing.makeWindow(from: raw)
        XCTAssertEqual(window.remaining, 2.10)
        XCTAssertEqual(window.unit, "USD")
    }
}
