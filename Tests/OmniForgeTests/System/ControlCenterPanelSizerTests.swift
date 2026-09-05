import AppKit
import XCTest
@testable import OmniForge

/// 尺寸适配器分步提交（阶段 0 实验 E3 的单元化覆盖 + SPEC §4.2/A2/A3）：
/// 曲线单调无过冲、等高短路、取消失效、完成回调一次性。
/// 测试使用未显示的 NSWindow（setFrame 仅存储值，隔离 WindowServer）。
@MainActor
final class ControlCenterPanelSizerTests: XCTestCase {
    private var window: NSWindow!
    private var sizer: ControlCenterPanelSizer!

    override func setUp() {
        super.setUp()
        // 未 orderFront 的窗口：setFrame 仅写内存，不上屏。
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        sizer = ControlCenterPanelSizer(window: window)
    }

    func test_interpolatedCurve_isMonotonicWithoutOvershoot() {
        // A3 逻辑侧：easeInOut 步进单调、端点精确、无过冲。
        let from: CGFloat = 560, to: CGFloat = 320
        var previous = from
        for step in 0...16 {
            let h = ControlCenterPanelSizer.interpolatedHeight(
                from: from, to: to, progress: CGFloat(step) / 16
            )
            XCTAssertLessThanOrEqual(h, previous + 0.0001, "收缩方向不得反向")
            XCTAssertGreaterThanOrEqual(h, to - 0.0001)
            XCTAssertLessThanOrEqual(h, from + 0.0001)
            previous = h
        }
        XCTAssertEqual(
            ControlCenterPanelSizer.interpolatedHeight(from: from, to: to, progress: 1), to
        )
        XCTAssertEqual(
            ControlCenterPanelSizer.interpolatedHeight(from: from, to: to, progress: 0), from
        )
        // 进度钳制：越界进度不得越过端点。
        XCTAssertEqual(ControlCenterPanelSizer.interpolatedHeight(from: from, to: to, progress: 1.5), to)
        XCTAssertEqual(ControlCenterPanelSizer.interpolatedHeight(from: from, to: to, progress: -0.5), from)
    }

    func test_equalHeightSubmit_completesImmediately() throws {
        var reached: Bool?
        let exp = expectation(description: "equal-height completion")
        sizer.submit(targetTotalHeight: 560, animationDuration: 0.15, onStep: { _ in }) { done in
            reached = done
            exp.fulfill()
        }
        // 未显示的窗口走同步确认路径。
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(reached, true)
        XCTAssertFalse(sizer.hasActiveSubmit)
    }

    func test_steppedSubmit_reachesTargetMonotonically() throws {
        // 分步序列到达终值；每步高度介于起终之间（单调段）。
        var steps: [CGFloat] = []
        let exp = expectation(description: "step completion")
        sizer.submit(targetTotalHeight: 320, animationDuration: 0.1, onStep: { steps.append($0) }) { _ in
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertFalse(steps.isEmpty)
        XCTAssertEqual(steps.last ?? 0, 320, accuracy: 0.51, "最后一步精确到达终值")
        XCTAssertEqual(window.frame.height, 320, accuracy: 0.51)
        for h in steps {
            XCTAssertLessThanOrEqual(h, 560.01)
            XCTAssertGreaterThanOrEqual(h, 319.49)
        }
        // 步间单调（相邻两步差方向一致且无反向跳变 >0.5pt）。
        for i in 1..<steps.count {
            XCTAssertLessThanOrEqual(steps[i], steps[i - 1] + 0.5, "收缩段不得反向")
        }
    }

    func test_cancel_invalidatesOldCompletion() throws {
        let exp = expectation(description: "interrupted completion")
        sizer.submit(targetTotalHeight: 320, animationDuration: 0.3, onStep: { _ in }) { reached in
            XCTAssertFalse(reached, "取消后不得报告到达")
            exp.fulfill()
        }
        // 立即取消：旧序列回调失效（interrupted=false 路径）。
        sizer.cancelActiveSubmits(interrupted: true)
        wait(for: [exp], timeout: 2)
        XCTAssertFalse(sizer.hasActiveSubmit)
    }

    func test_newSubmit_implicitlyCancelsOldSequence() throws {
        let first = expectation(description: "first interrupted")
        sizer.submit(targetTotalHeight: 480, animationDuration: 0.3, onStep: { _ in }) { reached in
            XCTAssertFalse(reached)
            first.fulfill()
        }
        let second = expectation(description: "second completes")
        sizer.submit(targetTotalHeight: 320, animationDuration: 0.08, onStep: { _ in }) { reached in
            XCTAssertTrue(reached)
            second.fulfill()
        }
        wait(for: [first, second], timeout: 5, enforceOrder: true)
        XCTAssertEqual(window.frame.height, 320, accuracy: 0.51)
    }

    func test_invalidTarget_reportsFailure() {
        let exp = expectation(description: "invalid target")
        sizer.submit(targetTotalHeight: .nan, animationDuration: 0.1, onStep: { _ in }) { reached in
            XCTAssertFalse(reached)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }
}
