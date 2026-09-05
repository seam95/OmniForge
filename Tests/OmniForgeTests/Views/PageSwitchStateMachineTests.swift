import XCTest
@testable import OmniForge

/// SPEC §6.2 状态机：latest-wins、阶段规则与收敛语义的确定性覆盖。
/// mounting 相位（自适应尺寸规格 §4.1 的透明准备/改高阶段）经
/// `mountCompleted` 推进；无屏障宿主在挂载点立即发 `mountCompleted`，
/// 时序与固定尺寸时代等价。
final class PageSwitchStateMachineTests: XCTestCase {
    typealias Machine = PageSwitchStateMachine<String>

    func test_requestingCurrentRouteInIdle_isIgnored() {
        var machine = Machine(initial: "a")
        machine.handle(.request("a"))
        XCTAssertEqual(machine.phase, .idle(displayed: "a"))
    }

    func test_idleRequestNewRoute_entersExiting() {
        var machine = Machine(initial: "a")
        machine.handle(.request("b"))
        XCTAssertEqual(machine.phase, .exiting(displayed: "a", pending: "b"))
    }

    func test_fullCycle_exitingMountingEnteringIdle() {
        var machine = Machine(initial: "a")
        machine.handle(.request("b"))
        machine.handle(.exitCompleted)
        XCTAssertEqual(machine.phase, .mounting(displayed: "b"))
        machine.handle(.mountCompleted)
        XCTAssertEqual(machine.phase, .entering(displayed: "b", pending: nil))
        machine.handle(.enterCompleted)
        XCTAssertEqual(machine.phase, .idle(displayed: "b"))
    }

    func test_multipleRequestsDuringExiting_keepOnlyLatestPending() {
        var machine = Machine(initial: "a")
        machine.handle(.request("b"))
        machine.handle(.request("c"))
        machine.handle(.request("d"))
        XCTAssertEqual(machine.phase, .exiting(displayed: "a", pending: "d"))
        machine.handle(.exitCompleted)
        XCTAssertEqual(machine.phase, .mounting(displayed: "d"))
        machine.handle(.mountCompleted)
        XCTAssertEqual(machine.phase, .entering(displayed: "d", pending: nil))
    }

    func test_requestDuringMountingWithoutQueue_replacesMountedTargetTransparently() {
        // SPEC §6.2：已挂载但尚未展示的目标可在透明阶段直接替换。
        var machine = Machine(initial: "a")
        machine.handle(.request("b"))
        machine.handle(.exitCompleted)
        machine.handle(.request("c"))
        XCTAssertEqual(machine.phase, .mounting(displayed: "c"))
    }

    func test_requestDuringMountingWithQueue_keepsMountedAndUpdatesQueue() {
        var machine = Machine(initial: "a")
        machine.handle(.request("b"))
        machine.handle(.exitCompleted)
        machine.handle(.request("c")) // 透明替换挂载目标为 c
        machine.handle(.request("d")) // 已有排队：仅更新队列
        XCTAssertEqual(machine.phase, .mounting(displayed: "d"))
    }

    func test_mountCompletedAfterTransparentReplacement_entersEnteringForLastTarget() {
        // 透明替换链：b→c→d 全程未展示，屏障完成直接淡入最后目标 d。
        var machine = Machine(initial: "a")
        machine.handle(.request("b"))
        machine.handle(.exitCompleted)
        machine.handle(.request("c"))
        machine.handle(.request("d"))
        machine.handle(.mountCompleted)
        XCTAssertEqual(machine.phase, .entering(displayed: "d", pending: nil))
    }

    func test_requestDuringEntering_isQueuedUntilEnterCompletes() {
        var machine = Machine(initial: "a")
        machine.handle(.request("b"))
        machine.handle(.exitCompleted)
        machine.handle(.mountCompleted)
        machine.handle(.request("c"))
        XCTAssertEqual(machine.phase, .entering(displayed: "b", pending: "c"))
        machine.handle(.enterCompleted)
        XCTAssertEqual(machine.phase, .exiting(displayed: "b", pending: "c"))
        machine.handle(.exitCompleted)
        XCTAssertEqual(machine.phase, .mounting(displayed: "c"))
    }

    func test_requestDisplayedRouteDuringEnteringWithoutQueue_isIgnored() {
        var machine = Machine(initial: "a")
        machine.handle(.request("b"))
        machine.handle(.exitCompleted)
        machine.handle(.mountCompleted)
        machine.handle(.request("b"))
        XCTAssertEqual(machine.phase, .entering(displayed: "b", pending: nil))
    }

    func test_queuedTargetEqualToDisplayed_resolvesToIdleWithoutNextExit() {
        var machine = Machine(initial: "a")
        machine.handle(.request("b"))
        machine.handle(.exitCompleted)
        machine.handle(.mountCompleted)
        machine.handle(.request("c"))
        machine.handle(.request("b"))
        machine.handle(.enterCompleted)
        XCTAssertEqual(machine.phase, .idle(displayed: "b"))
    }

    func test_cancelDuringExiting_convergesToLastRequestedRoute() {
        var machine = Machine(initial: "a")
        machine.handle(.request("b"))
        machine.handle(.request("c"))
        machine.handle(.cancel)
        XCTAssertEqual(machine.phase, .idle(displayed: "c"))
    }

    func test_cancelDuringMounting_convergesToQueuedOrMountedRoute() {
        var machine = Machine(initial: "a")
        machine.handle(.request("b"))
        machine.handle(.exitCompleted)
        machine.handle(.cancel)
        XCTAssertEqual(machine.phase, .idle(displayed: "b"))

        var queued = Machine(initial: "a")
        queued.handle(.request("b"))
        queued.handle(.exitCompleted)
        queued.handle(.request("c")) // 透明替换为 c
        queued.handle(.request("d")) // d 排队
        queued.handle(.cancel)
        XCTAssertEqual(queued.phase, .idle(displayed: "d"))
    }

    func test_cancelDuringEnteringWithQueue_convergesToQueuedRoute() {
        var machine = Machine(initial: "a")
        machine.handle(.request("b"))
        machine.handle(.exitCompleted)
        machine.handle(.mountCompleted)
        machine.handle(.request("c"))
        machine.handle(.cancel)
        XCTAssertEqual(machine.phase, .idle(displayed: "c"))
    }

    func test_cancelDuringEnteringWithoutQueue_keepsDisplayedRoute() {
        var machine = Machine(initial: "a")
        machine.handle(.request("b"))
        machine.handle(.exitCompleted)
        machine.handle(.mountCompleted)
        machine.handle(.cancel)
        XCTAssertEqual(machine.phase, .idle(displayed: "b"))
    }

    func test_exitCompletedOutsideExiting_isIgnored() {
        var machine = Machine(initial: "a")
        machine.handle(.exitCompleted)
        XCTAssertEqual(machine.phase, .idle(displayed: "a"))

        machine.handle(.request("b"))
        machine.handle(.exitCompleted)
        machine.handle(.exitCompleted) // 重入
        XCTAssertEqual(machine.phase, .mounting(displayed: "b"))
    }

    func test_mountCompletedOutsideMounting_isIgnored() {
        var machine = Machine(initial: "a")
        machine.handle(.mountCompleted)
        XCTAssertEqual(machine.phase, .idle(displayed: "a"))

        machine.handle(.request("b"))
        machine.handle(.mountCompleted) // 尚未 exitCompleted
        XCTAssertEqual(machine.phase, .exiting(displayed: "a", pending: "b"))
    }

    func test_enterCompletedOutsideEntering_isIgnored() {
        var machine = Machine(initial: "a")
        machine.handle(.enterCompleted)
        XCTAssertEqual(machine.phase, .idle(displayed: "a"))
    }

    func test_displayedRouteTracksPhaseAcrossFullCycle() {
        var machine = Machine(initial: "a")
        XCTAssertEqual(machine.displayedRoute, "a")
        machine.handle(.request("b"))
        XCTAssertEqual(machine.displayedRoute, "a", "exiting 期间 displayed 不变（旧页可见）")
        machine.handle(.exitCompleted)
        XCTAssertEqual(machine.displayedRoute, "b", "交换点 displayed 无动画替换（mounting 保持）")
        machine.handle(.mountCompleted)
        machine.handle(.enterCompleted)
        XCTAssertEqual(machine.displayedRoute, "b")
    }
}
