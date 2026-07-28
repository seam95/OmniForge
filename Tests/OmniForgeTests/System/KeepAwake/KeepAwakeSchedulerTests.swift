import Combine
import XCTest
@testable import OmniForge

@MainActor
final class KeepAwakeSchedulerTests: XCTestCase {
    func test_onceTask_firesOnlyOnce_andCancelPreventsFire() {
        let clock = FakeKeepAwakeClock(now: Date(timeIntervalSince1970: 0))
        let scheduler = FakeKeepAwakeScheduler(clock: clock)
        var count = 0
        let cancellable = scheduler.scheduleOnce(at: Date(timeIntervalSince1970: 10)) {
            count += 1
        }

        scheduler.advance(to: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(count, 1)

        // 再次推进不应重复触发
        scheduler.advance(to: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(count, 1)

        var cancelledCount = 0
        let cancelled = scheduler.scheduleOnce(at: Date(timeIntervalSince1970: 30)) {
            cancelledCount += 1
        }
        cancelled.cancel()
        scheduler.advance(to: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(cancelledCount, 0)
        _ = cancellable
    }

    func test_replaceDeadline_oldTaskDoesNotFire() {
        let clock = FakeKeepAwakeClock(now: Date(timeIntervalSince1970: 0))
        let scheduler = FakeKeepAwakeScheduler(clock: clock)
        var fired: [String] = []

        var first: AnyCancellable? = scheduler.scheduleOnce(at: Date(timeIntervalSince1970: 10)) {
            fired.append("old")
        }
        first?.cancel()
        first = nil

        let second = scheduler.scheduleOnce(at: Date(timeIntervalSince1970: 15)) {
            fired.append("new")
        }

        scheduler.advance(to: Date(timeIntervalSince1970: 15))
        XCTAssertEqual(fired, ["new"])
        _ = second
    }

    func test_repeatingTask_preservesIntervalAndTolerance() {
        let clock = FakeKeepAwakeClock()
        let scheduler = FakeKeepAwakeScheduler(clock: clock)
        var count = 0
        let cancellable = scheduler.scheduleRepeating(every: 30, tolerance: 5) {
            count += 1
        }

        XCTAssertEqual(scheduler.repeatingTasks.count, 1)
        XCTAssertEqual(scheduler.repeatingTasks[0].interval, 30)
        XCTAssertEqual(scheduler.repeatingTasks[0].tolerance, 5)

        scheduler.fireRepeating()
        scheduler.fireRepeating()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(scheduler.repeatingTasks[0].fireCount, 2)

        cancellable.cancel()
        scheduler.fireRepeating()
        XCTAssertEqual(count, 2)
    }
}
