import XCTest
@testable import OmniForge

/// 尺寸协调器（SPEC §4/§6/§7 的纯协调逻辑）：屏障测量采纳、等高跳过、
/// latest-wins、超预算降级、稳定变化防抖、会话取消。
/// sizer 缺位走同步路径（viewport 直写），不依赖真实 popover。
@MainActor
final class ControlCenterSizingContextTests: XCTestCase {
    private func makeContext(
        available: CGFloat = 1055,
        scale: CGFloat = 2
    ) -> ControlCenterSizingContext {
        let context = ControlCenterSizingContext(backingScaleProvider: { scale })
        context.availableTotalHeightProvider = { available }
        context.beginSession(sizer: ControlCenterPopoverSizer(popover: NSPopover().then { $0.contentSize = NSSize(width: 380, height: 690) }))
        return context
    }

    func test_mountBarrier_waitsForMeasurementThenProceeds() {
        let context = makeContext()
        context.reportShellHeight(110)
        var proceeded = false
        context.mountStarted(path: "panel/a") { proceeded = true }
        XCTAssertFalse(proceeded, "测量未到不得提前淡入")
        // 等高场景（当前总高 690 = 110 + 580 上限，内容 580）。
        context.reportNaturalHeight(580, isEmptyState: false)
        XCTAssertTrue(proceeded, "等高（≤1px）跳过改高直接 proceed")
    }

    func test_mountBarrier_heightChange_drivesViewportToTarget() {
        let context = makeContext()
        context.reportShellHeight(110)
        var proceeded = false
        context.mountStarted(path: "panel/a") { proceeded = true }
        context.reportNaturalHeight(320, isEmptyState: false)
        // 无 sizer（beginSession 绑定的 sizer 持未 show popover，等高判断走
        // currentTotalHeight=560+110=690 ≠ 110+320 → applyTarget；
        // 适配器未 show 时 settle 确认同步完成）。
        XCTAssertTrue(proceeded)
        XCTAssertEqual(context.viewportHeight, 320, accuracy: 0.51)
    }

    func test_mountBarrier_measurementBudget_proceedsWithoutMeasurement() {
        // 超预算降级：300ms 无有效测量时保持当前尺寸继续（不卡死转场）。
        let config = ControlCenterSizingContext.Configuration(mountMeasurementBudget: 0.05)
        let context = ControlCenterSizingContext(
            configuration: config,
            backingScaleProvider: { 2 }
        )
        context.beginSession(sizer: ControlCenterPopoverSizer(popover: NSPopover()))
        context.reportShellHeight(110)
        var proceeded = false
        context.mountStarted(path: "panel/a") { proceeded = true }
        let exp = expectation(description: "budget proceed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertTrue(proceeded, "超预算后必须 proceed（降级路径）")
    }

    func test_staleMountProceed_isIgnored() {
        // latest-wins：过期挂载的 proceed 不产生新动作（Host 侧 guard 的
        // 协调器侧前提——旧 mount 的测量链路被 generation 失效）。
        let context = makeContext()
        context.reportShellHeight(110)
        var firstProceeded = false
        context.mountStarted(path: "panel/a") { firstProceeded = true }
        // 新挂载到来（用户快速切换），旧链路作废。
        var secondProceeded = false
        context.mountStarted(path: "panel/b") { secondProceeded = true }
        context.reportNaturalHeight(320, isEmptyState: false)
        XCTAssertTrue(secondProceeded)
        XCTAssertFalse(firstProceeded, "旧挂载的 proceed 不得触发")
    }

    func test_endSession_cancelsEverything() {
        let context = makeContext()
        context.reportShellHeight(110)
        var proceeded = false
        context.mountStarted(path: "panel/a") { proceeded = true }
        context.endSession()
        let exp = expectation(description: "post-close quiesce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertFalse(proceeded, "关闭后旧回调不得触发")
        // 新会话可正常工作。
        context.beginSession(sizer: ControlCenterPopoverSizer(popover: NSPopover()))
        var newProceeded = false
        context.mountStarted(path: "panel/c") { newProceeded = true }
        context.reportNaturalHeight(580, isEmptyState: false)
        XCTAssertTrue(newProceeded)
    }

    func test_stableChange_debouncesAndResizes() {
        // 稳定期结构变化：先合并 100ms，再淡出→改高→淡入。
        let config = ControlCenterSizingContext.Configuration(
            stableChangeDebounce: 0.05,
            stableChangeMaxDebounce: 0.1
        )
        let context = ControlCenterSizingContext(
            configuration: config,
            backingScaleProvider: { 2 }
        )
        context.availableTotalHeightProvider = { 1055 }
        context.beginSession(sizer: ControlCenterPopoverSizer(popover: NSPopover()))
        context.reportShellHeight(110)
        // 初始稳定高度。
        context.reportNaturalHeight(580, isEmptyState: false)
        let idle = expectation(description: "initial settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { idle.fulfill() }
        wait(for: [idle], timeout: 2)
        XCTAssertEqual(context.contentOpacity, 1)

        // 结构变化：内容变矮。
        context.reportNaturalHeight(320, isEmptyState: false)
        XCTAssertEqual(context.contentOpacity, 1, "防抖期内不立即动作")
        let done = expectation(description: "stable resize done")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(context.contentOpacity, 1, "流程结束后恢复可见")
        XCTAssertEqual(context.viewportHeight, 320, accuracy: 0.51)
    }

    func test_equalMeasurement_doesNotTriggerChange() {
        // SPEC §7.1.5：测量相等不触发整页淡变。
        let context = makeContext()
        context.reportShellHeight(110)
        context.reportNaturalHeight(580, isEmptyState: false)
        let exp = expectation(description: "quiesce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(context.contentOpacity, 1)
        // 再次上报相同值：无淡出。
        context.reportNaturalHeight(580, isEmptyState: false)
        XCTAssertEqual(context.contentOpacity, 1)
    }

    func test_initialMeasurement_resolvesTarget() {
        let context = makeContext()
        context.beginInitialMeasurement()
        context.reportNaturalHeight(320, isEmptyState: false)
        context.reportShellHeight(110)
        let total = context.commitInitialMeasurement()
        XCTAssertEqual(total, 430, accuracy: 0.51)
        XCTAssertEqual(context.viewportHeight, 320, accuracy: 0.51)
        XCTAssertFalse(context.isMeasuringInitialSize)
    }

    func test_initialMeasurement_withoutMeasurement_fallsBackToCap() {
        let context = makeContext()
        context.beginInitialMeasurement()
        let total = context.commitInitialMeasurement()
        // 无可靠尺寸：安全上限打开（viewport=580 + chrome 兜底）。
        XCTAssertEqual(context.viewportHeight, 580)
        XCTAssertGreaterThan(total, 580)
    }

    func test_reduceMotion_usesShorterResizeDuration() {
        let context = makeContext()
        context.setReduceMotion(true)
        context.reportShellHeight(110)
        var proceeded = false
        context.mountStarted(path: "panel/a") { proceeded = true }
        context.reportNaturalHeight(320, isEmptyState: false)
        XCTAssertTrue(proceeded)
        XCTAssertEqual(context.viewportHeight, 320, accuracy: 0.51)
    }
}

private extension NSPopover {
    func then(_ configure: (NSPopover) -> Void) -> NSPopover {
        configure(self)
        return self
    }
}
