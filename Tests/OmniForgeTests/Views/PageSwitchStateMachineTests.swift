import XCTest
@testable import OmniForge

/// SPEC §6.2 状态机：latest-wins、阶段规则与收敛语义的确定性覆盖。
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

    func test_fullCycle_exitingEnteringIdle() {
        var machine = Machine(initial: "a")
        machine.handle(.request("b"))
        machine.handle(.exitCompleted)
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
        XCTAssertEqual(machine.phase, .entering(displayed: "d", pending: nil))
    }

    func test_requestDuringEntering_isQueuedUntilEnterCompletes() {
        var machine = Machine(initial: "a")
        machine.handle(.request("b"))
        machine.handle(.exitCompleted)
        machine.handle(.request("c"))
        XCTAssertEqual(machine.phase, .entering(displayed: "b", pending: "c"))
        machine.handle(.enterCompleted)
        XCTAssertEqual(machine.phase, .exiting(displayed: "b", pending: "c"))
        machine.handle(.exitCompleted)
        XCTAssertEqual(machine.phase, .entering(displayed: "c", pending: nil))
    }

    func test_requestDisplayedRouteDuringEnteringWithoutQueue_isIgnored() {
        var machine = Machine(initial: "a")
        machine.handle(.request("b"))
        machine.handle(.exitCompleted)
        machine.handle(.request("b"))
        XCTAssertEqual(machine.phase, .entering(displayed: "b", pending: nil))
    }

    func test_queuedTargetEqualToDisplayed_resolvesToIdleWithoutNextExit() {
        var machine = Machine(initial: "a")
        machine.handle(.request("b"))
        machine.handle(.exitCompleted)
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

    func test_cancelDuringEnteringWithQueue_convergesToQueuedRoute() {
        var machine = Machine(initial: "a")
        machine.handle(.request("b"))
        machine.handle(.exitCompleted)
        machine.handle(.request("c"))
        machine.handle(.cancel)
        XCTAssertEqual(machine.phase, .idle(displayed: "c"))
    }

    func test_cancelDuringEnteringWithoutQueue_keepsDisplayedRoute() {
        var machine = Machine(initial: "a")
        machine.handle(.request("b"))
        machine.handle(.exitCompleted)
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
        XCTAssertEqual(machine.phase, .entering(displayed: "b", pending: nil))
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
        XCTAssertEqual(machine.displayedRoute, "b", "交换点 displayed 无动画替换")
        machine.handle(.enterCompleted)
        XCTAssertEqual(machine.displayedRoute, "b")
    }
}
