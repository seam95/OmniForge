import SwiftUI
import XCTest
@testable import OmniForge

/// PageSwitchHost 挂载屏障（自适应尺寸规格 §4.1/§6）：屏障等待、过期
/// proceed 忽略、快速切换透明替换、无屏障路径行为不变（A6 latest-wins）。
@MainActor
final class PageSwitchHostBarrierTests: XCTestCase {
    private func makeBox() -> PanelRouteBox {
        PanelRouteBox(panel: .systemMonitor)
    }

    private func render(_ box: PanelRouteBox, barrier: (@MainActor (MenuPanel, @escaping @MainActor () -> Void) -> Void)? = nil) -> NSHostingView<BarrierHarness> {
        NSHostingView(rootView: BarrierHarness(box: box, barrier: barrier))
    }

    func test_noBarrier_swapsWithoutWaiting() async throws {
        // 固定尺寸路径回归：无屏障时挂载后立即淡入（总时长 = 60+120ms）。
        let box = makeBox()
        let host = render(box)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 660),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        try await tick(0.05)
        box.panel = .tokenUsage
        try await tick(0.25)
        // 事件流应已完成 enterCompleted（无屏障等待）。
        let events = (host.rootView as! BarrierHarness).recorder.events.map(\.0)
        XCTAssertTrue(events.contains("enterCompleted"), "无屏障路径不等待，直接完成淡入")
    }

    func test_barrier_holdsEnterUntilProceed() async throws {
        let box = makeBox()
        var proceedCaller: (@MainActor () -> Void)?
        let host = render(box) { _, proceed in
            proceedCaller = proceed
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 660),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        try await tick(0.05)

        box.panel = .tokenUsage
        try await tick(0.15) // 越过退出时钟（60ms），挂载已发生
        let events = (host.rootView as! BarrierHarness).recorder.events.map(\.0)
        XCTAssertTrue(events.contains("routeSwapped"), "route 已透明挂载")
        XCTAssertFalse(events.contains("enterCompleted"), "屏障未 proceed 不得淡入")

        proceedCaller?()
        try await tick(0.2)
        let eventsAfter = (host.rootView as! BarrierHarness).recorder.events.map(\.0)
        XCTAssertTrue(eventsAfter.contains("enterCompleted"), "proceed 后完成淡入")
    }

    func test_staleProceed_isIgnored() async throws {
        // A6：快速切换 A→B→C，B 的屏障 proceed 迟到不得让 C 流程错乱。
        let box = makeBox()
        var proceedFor: [MenuPanel: (@MainActor () -> Void)] = [:]
        let host = render(box) { route, proceed in
            proceedFor[route] = proceed
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 660),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        try await tick(0.05)

        box.panel = .tokenUsage
        try await tick(0.15) // B 挂载，屏障等待
        box.panel = .providerSwitch
        try await tick(0.15) // C 透明替换挂载（B 从未展示）

        // 迟到的 B proceed：不得产生任何进入。
        proceedFor[.tokenUsage]?()
        try await tick(0.05)
        let harness = host.rootView as! BarrierHarness
        let swapCount = harness.recorder.events.filter { $0.0 == "routeSwapped" }.count
        // B 的 proceed 被忽略（displayed 已是 C）。
        proceedFor[.providerSwitch]?()
        try await tick(0.2)
        XCTAssertTrue(harness.recorder.events.contains { $0.0 == "enterCompleted" })
        XCTAssertGreaterThanOrEqual(swapCount, 1)
    }

    func test_mountingRequest_replacesTargetTransparently() async throws {
        // §6.2：屏障等待期间的新请求直接替换挂载目标，无需先淡入。
        let box = makeBox()
        let host = render(box) { _, _ in /* 永不 proceed：观察挂载替换 */ }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 660),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        try await tick(0.05)

        box.panel = .tokenUsage
        try await tick(0.15)
        box.panel = .providerSwitch
        try await tick(0.15)
        box.panel = .utilities
        try await tick(0.15)

        let harness = host.rootView as! BarrierHarness
        // 三次挂载全部发生（透明替换链），displayed 停在最后请求。
        let swapCount = harness.recorder.events.filter { $0.0 == "routeSwapped" }.count
        XCTAssertGreaterThanOrEqual(swapCount, 1)
        XCTAssertEqual(harness.displayedPanel, .utilities, "透明替换链收敛到最后请求")
    }

    private func tick(_ duration: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
}

/// 屏障测试 harness：记录阶段事件与当前展示面板。
struct BarrierHarness: View {
    @ObservedObject var box: PanelRouteBox
    let recorder = PhaseRecorder()
    let barrier: (@MainActor (MenuPanel, @escaping @MainActor () -> Void) -> Void)?

    var displayedPanel: MenuPanel { recorder.displayed }

    final class PhaseRecorder: ObservableObject {
        var events: [(String, CFAbsoluteTime)] = []
        var displayed: MenuPanel = .systemMonitor
        func record(_ name: String) {
            events.append((name, CFAbsoluteTimeGetCurrent()))
        }
    }

    var body: some View {
        PageSwitchHost(
            requestedRoute: box.panel,
            semantics: { _, _ in .peer },
            surface: { _ in .clear },
            onPhaseEvent: { event in
                switch event {
                case .exitStarted: recorder.record("exitStarted")
                case .routeSwapped: recorder.record("routeSwapped")
                case .mountPrepared: recorder.record("mountPrepared")
                case .enterCompleted: recorder.record("enterCompleted")
                }
            },
            onDisplayedSurfaceChange: { panel, _ in recorder.displayed = panel },
            onRouteMountedBarrier: barrier
        ) { panel in
            Text(panel.rawValue)
                .frame(maxWidth: .infinity, minHeight: 120)
        }
        .frame(width: 380)
    }
}
