import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// SPEC §6.1/§6.3：Host 单活动树、latest-wins 收敛、阶段顺序与 Reduce Motion 同状态机。
@MainActor
final class PageSwitchHostTests: XCTestCase {

    // MARK: - 单活动树（SPEC §6.3.5）

    func test_switchKeepsSingleActiveContentTree() async throws {
        let probe = try await mountHarness(initial: "a")
        XCTAssertEqual(probe.mounts.current, 1, "初始仅一棵内容树")

        probe.request("b")
        await waitForIdle(probe)

        XCTAssertEqual(
            probe.mounts.peak, 1,
            "转场全程（exiting → 交换 → entering）最多一棵完整内容树"
        )
        XCTAssertEqual(probe.mounts.current, 1)
        XCTAssertEqual(probe.events, [.exitStarted, .routeSwapped, .enterCompleted])
    }

    // MARK: - latest-wins 与收敛（SPEC §3.1.7）

    func test_rapidRequestsConvergeToLatestRoute() async throws {
        let probe = try await mountHarness(initial: "a")
        for route in ["b", "c", "d", "e", "a"] {
            probe.request(route)
            try await tick(0.01)
        }
        await waitForIdle(probe)

        XCTAssertEqual(probe.mounts.current, 1)
        XCTAssertEqual(
            probe.displayedRoute, "a",
            "快速连续请求 latest-wins，最终展示最后一次有效选择"
        )
        XCTAssertEqual(probe.events.last, .enterCompleted)
    }

    func test_sameRouteRequest_startsNoPhase() async throws {
        let probe = try await mountHarness(initial: "a")
        probe.request("a")
        try await tick(0.2)

        XCTAssertTrue(probe.events.isEmpty, "相同 route 请求不得启动任何阶段")
        XCTAssertEqual(probe.mounts.current, 1)
    }

    // MARK: - 阶段顺序（SPEC §8.2）

    func test_routeSwapHappensAfterExitAndBeforeEnter() async throws {
        let probe = try await mountHarness(initial: "a")
        probe.request("b")
        await waitForIdle(probe)

        let swapIndex = try XCTUnwrap(
            probe.events.firstIndex(of: .routeSwapped),
            "切换必须产生 route 交换事件"
        )
        XCTAssertGreaterThan(
            swapIndex, probe.events.firstIndex(of: .exitStarted) ?? -1,
            "背景与内容的交换点必须在旧内容退出完成之后"
        )
        XCTAssertEqual(
            probe.events.last, .enterCompleted,
            "进入完成是最后一个事件"
        )
    }

    // MARK: - Reduce Motion（SPEC §7.4 / §14.3）

    func test_reduceMotion_runsSameStateMachine() async throws {
        let probe = try await mountHarness(initial: "a", reduceMotion: true)
        probe.request("b")
        await waitForIdle(probe)

        XCTAssertEqual(
            probe.events, [.exitStarted, .routeSwapped, .enterCompleted],
            "Reduce Motion 走相同状态机，只降级动效参数"
        )
        XCTAssertEqual(probe.mounts.peak, 1)
    }

    // MARK: - 交互门控（SPEC §11.1）

    /// 真实鼠标事件断言（SPEC §11.1）：向内容探针中心发送 mouseDown，
    /// 转场窗口内探针不得收到（allowsHitTesting 门控生效），稳定后恢复接收；
    /// 同一窗口内导航仍接受最新请求。
    /// 注：离屏环境 AppKit hitTest 对 SwiftUI 内容两种状态均穿透，无区分度；
    /// 事件派发路径（NSApp.sendEvent → SwiftUI 命中分发）是唯一可测通道。
    func test_hitTesting_blocksContentHitsDuringTransition() async throws {
        let probe = try await mountHarness(initial: "a")

        // sanity：稳定态探针可接收鼠标事件。
        probe.sendMouseDownAtContentProbe()
        XCTAssertEqual(probe.contentProbeHitCount, 1, "sanity：稳定态内容探针接收事件")

        probe.request("b")
        try await tick(0.02) // 退出窗口（60ms）内
        probe.sendMouseDownAtContentProbe()
        let blockedDuringExit = probe.contentProbeHitCount == 1
        // 同一窗口内模拟导航点击新 route（导航区不受内容门控影响）。
        probe.request("c")
        await waitForIdle(probe)

        probe.sendMouseDownAtContentProbe()
        XCTAssertTrue(
            blockedDuringExit,
            "exiting 阶段内容探针不得收到鼠标事件（删掉 allowsHitTesting 本断言变红）"
        )
        XCTAssertEqual(probe.contentProbeHitCount, 2, "idle 阶段内容探针恢复接收事件")
        XCTAssertEqual(probe.displayedRoute, "c", "转场窗口内导航仍接受最新请求")
    }

    // MARK: - 背景表面（SPEC §8.2.2/§8.2.3）

    func test_surfaceUpdatesOnlyAtSwapPoint() async throws {
        let probe = try await mountHarness(initial: "a")
        XCTAssertEqual(probe.displayedSurface?.description, Color.red.description)

        probe.request("b")
        try await tick(0.02) // 退出窗口内：背景仍为旧 route 表面
        XCTAssertEqual(
            probe.displayedSurface, Color.red,
            "旧页面可见期间背景保持不变"
        )

        await waitForIdle(probe)
        XCTAssertEqual(
            probe.displayedSurface, Color.blue,
            "背景仅在交换点更新为新 route 表面"
        )
    }

    // MARK: - harness

    private func mountHarness(
        initial: String,
        reduceMotion: Bool = false
    ) async throws -> HostProbe {
        let probe = HostProbe(initialRoute: initial)
        let harness = ProbeHarness(probe: probe, reduceMotion: reduceMotion)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 580),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: harness)
        window.orderFrontRegardless()
        probe.window = window
        try await tick(0.05)
        return probe
    }

    private func waitForIdle(_ probe: HostProbe, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !probe.isIdle && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(probe.isIdle, "状态机必须在超时内收敛到 idle")
    }

    private func tick(_ duration: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
}

/// Host 观测探针：请求 route、挂载计数、阶段事件、displayed route/surface、
/// 内容区 hitTest（真实交互门控断言）。
@MainActor
final class HostProbe: ObservableObject {
    @Published private(set) var route: String
    private(set) var displayedRoute: String
    private(set) var displayedSurface: Color?
    private(set) var mounts = MountTally()
    private(set) var events: [PageSwitchPhaseEvent] = []
    weak var window: NSWindow?

    /// 记录型内容探针的 mouseDown 计数。
    private(set) var contentProbeHitCount = 0

    fileprivate func recordContentProbeHit() {
        contentProbeHitCount += 1
    }

    /// 向内容探针中心发送一次真实 mouseDown 事件（经 NSApp 派发，
    /// 走 SwiftUI 命中分发路径——allowsHitTesting 在该路径生效）。
    func sendMouseDownAtContentProbe() {
        guard let window,
              let hosting = window.contentView,
              let frame = hosting.frame(for: .hitProbe) else { return }
        let point = NSPoint(x: frame.midX, y: frame.midY)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: hosting.convert(point, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { return }
        NSApp.sendEvent(event)
    }

    init(initialRoute: String) {
        self.route = initialRoute
        self.displayedRoute = initialRoute
    }

    var isIdle: Bool {
        events.last == .enterCompleted
    }

    var isTransitioning: Bool {
        if events.isEmpty { return false }
        return events.last != .enterCompleted
    }

    func request(_ newRoute: String) {
        route = newRoute
    }

    fileprivate func mountDelta(_ delta: Int) {
        mounts.bump(delta)
    }

    fileprivate func record(_ event: PageSwitchPhaseEvent) {
        events.append(event)
    }

    fileprivate func displayDidSwap(route: String, surface: Color?) {
        displayedRoute = route
        displayedSurface = surface
    }
}

@MainActor
final class MountTally {
    private(set) var current = 0
    private(set) var peak = 0

    func bump(_ delta: Int) {
        current += delta
        peak = max(peak, current)
    }
}

private struct ProbeHarness: View {
    @ObservedObject var probe: HostProbe
    let reduceMotion: Bool

    var body: some View {
        PageSwitchHost(
            requestedRoute: probe.route,
            semantics: { _, _ in .peer },
            surface: { route in
                PageSurface(background: route == "a" ? .red : .blue)
            },
            reduceMotionOverride: reduceMotion,
            contentMountObserver: { delta in probe.mountDelta(delta) },
            onPhaseEvent: { event in probe.record(event) },
            onDisplayedSurfaceChange: { route, surface in
                probe.displayDidSwap(route: route, surface: surface.background)
            }
        ) { route in
            VStack(spacing: 0) {
                HitProbeRepresentable { probe.recordContentProbeHit() }
                    .frame(height: 40)
                Text("content-\(route)")
                    .padding(20)
            }
        }
    }
}

/// 内容区命中探针：记录 mouseDown 次数（identifier 供事件定位）。
final class HitRecordingProbeView: NSView {
    var onReceived: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onReceived?()
    }
}

private struct HitProbeRepresentable: NSViewRepresentable {
    let onReceived: () -> Void

    func makeNSView(context: Context) -> HitRecordingProbeView {
        let view = HitRecordingProbeView()
        view.identifier = .hitProbe
        view.onReceived = onReceived
        return view
    }

    func updateNSView(_ nsView: HitRecordingProbeView, context: Context) {
        nsView.onReceived = onReceived
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let hitProbe = NSUserInterfaceItemIdentifier("PageSwitchHostTests.hitProbe")
}

private extension NSView {
    /// 深度优先查找 identifier 后代，返回其位于本视图坐标系的 frame。
    func frame(for identifier: NSUserInterfaceItemIdentifier) -> NSRect? {
        for subview in subviews {
            if subview.identifier == identifier {
                return convert(subview.bounds, from: subview)
            }
            if let found = subview.frame(for: identifier) {
                return found
            }
        }
        return nil
    }
}
