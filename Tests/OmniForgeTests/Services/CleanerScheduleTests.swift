import XCTest
@testable import OmniForge

/// 固定 CleanerSchedule 的日历数学边界 —— 午夜、正午、跨日始终绊倒人。
final class CleanerScheduleTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: nextFireDate

    func test_nextFireDate_offReturnsNil() {
        XCTAssertNil(CleanerSchedule.nextFireDate(after: date(2026, 1, 1, 10, 0),
                                                  frequency: .off, hour: 9, minute: 0, weekday: 2,
                                                  calendar: calendar))
    }

    func test_nextFireDate_daily_futureSameDay() {
        // 10:00 问每日 9:00 → 当天已过，返回次日 9:00
        let next = CleanerSchedule.nextFireDate(after: date(2026, 1, 1, 10, 0),
                                                frequency: .daily, hour: 9, minute: 0, weekday: 2,
                                                calendar: calendar)
        XCTAssertEqual(next, date(2026, 1, 2, 9, 0))
    }

    func test_nextFireDate_daily_beforeTargetTime() {
        // 8:00 问每日 9:00 → 当天 9:00
        let next = CleanerSchedule.nextFireDate(after: date(2026, 1, 1, 8, 0),
                                                frequency: .daily, hour: 9, minute: 0, weekday: 2,
                                                calendar: calendar)
        XCTAssertEqual(next, date(2026, 1, 1, 9, 0))
    }

    func test_nextFireDate_weekday_clampsToChosenWeekday() {
        // 2026-01-01 是周四（weekday 5）。每周一（weekday 2）9:00 → 下周一 1/5
        let next = CleanerSchedule.nextFireDate(after: date(2026, 1, 1, 10, 0),
                                                frequency: .weekly, hour: 9, minute: 0, weekday: 2,
                                                calendar: calendar)
        XCTAssertEqual(next, date(2026, 1, 5, 9, 0))
    }

    // MARK: hour24 / hour12Components

    func test_hour24_midnight() {
        XCTAssertEqual(CleanerSchedule.hour24(hour12: 12, isPM: false), 0)
    }

    func test_hour24_noon() {
        XCTAssertEqual(CleanerSchedule.hour24(hour12: 12, isPM: true), 12)
    }

    func test_hour24_afternoon() {
        XCTAssertEqual(CleanerSchedule.hour24(hour12: 3, isPM: true), 15)
    }

    func test_hour24_morning() {
        XCTAssertEqual(CleanerSchedule.hour24(hour12: 9, isPM: false), 9)
    }

    func test_hour12Components_midnight() {
        let result = CleanerSchedule.hour12Components(fromHour24: 0)
        XCTAssertEqual(result.hour12, 12)
        XCTAssertFalse(result.isPM)
    }

    func test_hour12Components_noon() {
        let result = CleanerSchedule.hour12Components(fromHour24: 12)
        XCTAssertEqual(result.hour12, 12)
        XCTAssertTrue(result.isPM)
    }

    func test_hour12Components_roundTrip() {
        for h24 in 0...23 {
            let comps = CleanerSchedule.hour12Components(fromHour24: h24)
            XCTAssertEqual(CleanerSchedule.hour24(hour12: comps.hour12, isPM: comps.isPM), h24,
                           "round-trip 失败于 \(h24):00")
        }
    }

    // MARK: missedRun

    func test_missedRun_offNeverMisses() {
        XCTAssertFalse(CleanerSchedule.missedRun(now: date(2026, 6, 1, 10, 0),
                                                 lastRun: date(2026, 1, 1, 9, 0),
                                                 frequency: .off, hour: 9, minute: 0, weekday: 2,
                                                 calendar: calendar))
    }

    func test_missedRun_neverRanReturnsFalse() {
        XCTAssertFalse(CleanerSchedule.missedRun(now: date(2026, 6, 1, 10, 0),
                                                 lastRun: nil,
                                                 frequency: .daily, hour: 9, minute: 0, weekday: 2,
                                                 calendar: calendar),
                       "从未运行过：调度从现在开始，不搞追补")
    }

    func test_missedRun_dueInPastReturnsTrue() {
        // 昨天运行过，每日 9:00，现在已过今天的 9:00 → 错过
        XCTAssertTrue(CleanerSchedule.missedRun(now: date(2026, 1, 2, 10, 0),
                                                lastRun: date(2026, 1, 1, 9, 0),
                                                frequency: .daily, hour: 9, minute: 0, weekday: 2,
                                                calendar: calendar))
    }

    func test_missedRun_notYetDueReturnsFalse() {
        // 今天运行过，每日 9:00，现在还在 9:00 之前 → 未错过
        XCTAssertFalse(CleanerSchedule.missedRun(now: date(2026, 1, 1, 8, 0),
                                                 lastRun: date(2026, 1, 1, 9, 0),
                                                 frequency: .daily, hour: 9, minute: 0, weekday: 2,
                                                 calendar: calendar))
    }
}
