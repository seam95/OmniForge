import XCTest
import UserNotifications
@testable import OmniForge

/// 生产提醒调度器的触发器语义测试（跨时区 / 夏令时修复回归）。
/// 提醒是双通道：内部 Timer 唤起窗口（绝对时刻）+ 系统通知横幅。
/// 通知触发器必须同为绝对时刻语义，否则时区 / DST 变化后两通道错位，
/// 横幅与窗口唤起在两个不同时刻各响一次。
@MainActor
final class StickyNoteReminderSchedulingTests: XCTestCase {
    private var scheduler: SystemStickyNoteReminderScheduler!

    override func setUp() {
        super.setUp()
        scheduler = SystemStickyNoteReminderScheduler()
    }

    // MARK: - 未来时刻：固定偏移（绝对时刻语义）

    /// 必须返回相对挂载时刻的固定偏移触发器，偏移 ≈ date.timeIntervalSinceNow。
    /// 旧的 UNCalendarNotificationTrigger 用无时区 DateComponents 表达墙上时间：
    /// 时区 / 夏令时变化后系统按新墙上时间重算触发点，绝对时刻随之漂移。
    func test_trigger_usesTimeIntervalTriggerFromNow() {
        let date = Date().addingTimeInterval(5 * 60)

        let trigger = scheduler.trigger(for: date)

        XCTAssertTrue(
            trigger is UNTimeIntervalNotificationTrigger,
            "必须用固定偏移触发器，不得用墙上时间语义的日历触发器"
        )
        let intervalTrigger = trigger as? UNTimeIntervalNotificationTrigger
        XCTAssertEqual(
            intervalTrigger?.timeInterval ?? -1,
            date.timeIntervalSinceNow,
            accuracy: 1,
            "偏移应约等于 date.timeIntervalSinceNow（容差 1s 吸收断言前后的执行耗时）"
        )
        XCTAssertFalse(intervalTrigger?.repeats ?? true, "提醒通知只投递一次")
    }

    // MARK: - 过去时刻：不补发通知

    /// 过去时刻返回 nil，沿用恢复语义：过期未触发的提醒走唤醒标记，不补发通知。
    func test_trigger_pastDateReturnsNil() {
        let past = Date().addingTimeInterval(-60)

        XCTAssertNil(scheduler.trigger(for: past), "过去时刻不得再排通知")
    }
}
