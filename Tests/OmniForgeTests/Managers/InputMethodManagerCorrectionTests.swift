import Foundation
import XCTest
@testable import OmniForge

final class InputMethodManagerCorrectionTests: XCTestCase {
    func test_whenLockedAndMismatch_correctsBackAfterDelay() {
        let tis = FakeTISClient(
            inputSources: [
                .init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil),
                .init(id: "b", name: "B", isSelectable: true, isEnabled: true, icon: nil)
            ],
            currentID: "b"
        )

        let scheduler = ImmediateScheduler()
        let manager = InputMethodManager(tis: tis, scheduler: scheduler)

        manager.correctIfNeeded(isLocked: true, lockedID: "a")
        XCTAssertEqual(tis.currentInputSourceID(), "a")
    }

    func test_whenUnlocked_noCorrection() {
        let tis = FakeTISClient(
            inputSources: [
                .init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil),
                .init(id: "b", name: "B", isSelectable: true, isEnabled: true, icon: nil)
            ],
            currentID: "b"
        )

        let scheduler = ImmediateScheduler()
        let manager = InputMethodManager(tis: tis, scheduler: scheduler)

        manager.correctIfNeeded(isLocked: false, lockedID: "a")
        XCTAssertEqual(tis.currentInputSourceID(), "b")
    }

    // MARK: - 防抖缩窗（Task 11：快速二次切换不得被吞掉）

    func test_secondSwitchAt0_2Seconds_stillGetsCorrected() {
        let tis = FakeTISClient(
            inputSources: [
                .init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil),
                .init(id: "b", name: "B", isSelectable: true, isEnabled: true, icon: nil)
            ],
            currentID: "b"
        )
        let scheduler = ManualClockScheduler()
        let manager = InputMethodManager(tis: tis, scheduler: scheduler)

        // t=0：用户切到 B，锁定纠正立即拉回 A（0.05s 后确认成功）
        manager.correctIfNeeded(isLocked: true, lockedID: "a")
        scheduler.advance(by: 0.05)
        // 推进到 t=0.2：纠正窗口（重试链长度）结束
        scheduler.advance(by: 0.15)

        // t=0.2：旧 0.5s 防抖窗口内的二次切换（快速双击快捷键场景）仍必须被纠正
        tis.selectInputSource(id: "b")
        manager.correctIfNeeded(isLocked: true, lockedID: "a")

        XCTAssertEqual(tis.currentInputSourceID(), "a")
    }

    func test_switchAt0_6Seconds_corrected_andSelfCorrectionDoesNotLoop() {
        let tis = FakeTISClient(
            inputSources: [
                .init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil),
                .init(id: "b", name: "B", isSelectable: true, isEnabled: true, icon: nil)
            ],
            currentID: "b"
        )
        let scheduler = ManualClockScheduler()
        let manager = InputMethodManager(tis: tis, scheduler: scheduler)

        // t=0 完成第一次纠正并推进过纠正窗口
        manager.correctIfNeeded(isLocked: true, lockedID: "a")
        scheduler.advance(by: 0.05)
        scheduler.advance(by: 0.15)
        // 推进到 t=0.6（旧防抖窗口之后）
        scheduler.advance(by: 0.4)

        // t=0.6：真实用户切换仍被纠正（防回环守卫不影响正常纠正）
        tis.selectInputSource(id: "b")
        manager.correctIfNeeded(isLocked: true, lockedID: "a")
        XCTAssertEqual(tis.currentInputSourceID(), "a")

        // 推进到本次纠正链确认成功且窗口结束
        scheduler.advance(by: 0.05)
        scheduler.advance(by: 0.15)

        // 模拟自身纠正触发的输入法变化通知：current == lockedID 时
        // 前置守卫应直接返回，不得启动新纠正链（无新增待执行任务）
        manager.correctIfNeeded(isLocked: true, lockedID: "a")
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(tis.currentInputSourceID(), "a")
    }

    // MARK: - 重试耗尽暴露失败（Task 11：锁定失效可观察）

    func test_retryExhausted_exposesError_andManualReturnClearsIt() {
        let tis = StubbornTISClient(currentID: "b")
        let scheduler = ManualClockScheduler()
        let manager = InputMethodManager(tis: tis, scheduler: scheduler)

        // 系统竞态导致全部 4 次尝试失败（首次 + 3 次重试）
        manager.correctIfNeeded(isLocked: true, lockedID: "a")
        scheduler.advance(by: 0.2)

        XCTAssertEqual(tis.selectCallCount, 4)
        XCTAssertNotNil(manager.lastCorrectionError)

        // 用户手动切回锁定输入法后，陈旧错误应被前置守卫清除
        tis.currentID = "a"
        manager.correctIfNeeded(isLocked: true, lockedID: "a")
        XCTAssertNil(manager.lastCorrectionError)
    }

    func test_laterSuccessfulCorrection_clearsStaleError() {
        let tis = StubbornTISClient(currentID: "b")
        let scheduler = ManualClockScheduler()
        let manager = InputMethodManager(tis: tis, scheduler: scheduler)

        manager.correctIfNeeded(isLocked: true, lockedID: "a")
        scheduler.advance(by: 0.2)
        XCTAssertNotNil(manager.lastCorrectionError)

        // 竞态解除后，下一次纠正成功应清除错误状态
        tis.correctionShouldSucceed = true
        manager.correctIfNeeded(isLocked: true, lockedID: "a")
        scheduler.advance(by: 0.05)

        XCTAssertNil(manager.lastCorrectionError)
        XCTAssertEqual(tis.currentInputSourceID(), "a")
    }
}

/// 虚拟时钟调度器：测试手动推进时间，按到期顺序执行任务
private final class ManualClockScheduler: Scheduler {
    private var now: TimeInterval = 0
    private var tasks: [(fireAt: TimeInterval, block: () -> Void)] = []

    /// 尚未到期执行的任务数
    var pendingCount: Int { tasks.count }

    func after(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        tasks.append((now + delay, block))
    }

    /// 推进虚拟时间：按到期时刻升序执行任务；
    /// 执行时把时钟拨到该任务到期时刻，保证任务中新调度的任务基于正确时刻
    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while let index = indexOfEarliestTask(atOrBefore: target) {
            let task = tasks.remove(at: index)
            now = task.fireAt
            task.block()
        }
        now = max(now, target)
    }

    private func indexOfEarliestTask(atOrBefore target: TimeInterval) -> Int? {
        var best: Int?
        for (index, task) in tasks.enumerated() where task.fireAt <= target {
            // 严格小于：到期时刻相同时保持入队顺序
            if best == nil || task.fireAt < tasks[best!].fireAt {
                best = index
            }
        }
        return best
    }
}

/// 可控失败的 TIS 桩：模拟系统竞态导致纠正切换不生效
private final class StubbornTISClient: TISClient {
    private let sources: [InputSource]
    var currentID: String?
    /// 纠正切换是否生效；false 时 select 始终失败（模拟系统竞态）
    var correctionShouldSucceed = false
    private(set) var selectCallCount = 0

    init(currentID: String?) {
        self.sources = [
            .init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil),
            .init(id: "b", name: "B", isSelectable: true, isEnabled: true, icon: nil)
        ]
        self.currentID = currentID
    }

    func listInputSources() -> [InputSource] { sources }
    func currentInputSourceID() -> String? { currentID }
    func selectInputSource(id: String) -> Bool {
        selectCallCount += 1
        guard correctionShouldSucceed else { return false }
        currentID = id
        return true
    }
}
