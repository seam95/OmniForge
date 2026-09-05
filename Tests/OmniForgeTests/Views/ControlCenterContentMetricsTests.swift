import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// 控制中心壳层尺寸契约：固定宽度与 viewport 上限（自适应高度 SPEC §3.1）。
final class ControlCenterContentMetricsTests: XCTestCase {
    func test_metrics_matchControlCenterShellContract() {
        XCTAssertEqual(ControlCenterContentMetrics.panelWidth, 380)
        XCTAssertEqual(ControlCenterContentMetrics.viewportHeight, 580)
        XCTAssertEqual(ControlCenterContentMetrics.emptyContentMinHeight, 120)
    }
}

/// 阶段稳定性采样：转场时间线（exitStarted → routeSwapped → mountPrepared →
/// enterCompleted）与外壳高度序列，验证自适应契约（SPEC §8）：
/// - 淡出期间（exitStarted…routeSwapped）高度不变；
/// - 改高连续单调（相邻采样无反向跳变）；
/// - 稳定后高度等于目标且 500ms 内无补跳。
@MainActor
final class ControlCenterViewportStabilityTests: XCTestCase {
    final class Sample {
        let time: CFAbsoluteTime
        let phaseEvent: String
        let totalHeight: CGFloat
        init(time: CFAbsoluteTime, phaseEvent: String, totalHeight: CGFloat) {
            self.time = time
            self.phaseEvent = phaseEvent
            self.totalHeight = totalHeight
        }
    }

    @MainActor
    final class Recorder: ObservableObject {
        var samples: [Sample] = []
        var events: [(String, CFAbsoluteTime)] = []
        let t0 = CFAbsoluteTimeGetCurrent()

        func record(height: CGFloat) {
            samples.append(Sample(time: CFAbsoluteTimeGetCurrent(), phaseEvent: "", totalHeight: height))
        }

        func event(_ name: String) {
            events.append((name, CFAbsoluteTimeGetCurrent()))
        }

        /// 淡出窗口（最近一次 exitStarted 到其后的 routeSwapped）内的采样：
        /// 改高发生在 routeSwapped 之后的 mounting，故窗口右端不含余量。
        func heightsPerExitWindow() -> [[CGFloat]] {
            var windows: [(CFAbsoluteTime, CFAbsoluteTime)] = []
            var exitStart: CFAbsoluteTime?
            for (name, t) in events {
                if name == "exitStarted" { exitStart = t }
                if name == "routeSwapped", let start = exitStart {
                    windows.append((start, t))
                    exitStart = nil
                }
            }
            return windows.map { window in
                samples
                    .filter { $0.time >= window.0 && $0.time <= window.1 }
                    .map(\.totalHeight)
            }
        }
    }

    func test_exitWindows_heightStable_settlesToTarget_noLateJump() async throws {
        let box = PanelRouteBox(panel: .systemMonitor)
        let recorder = Recorder()
        let context = ControlCenterSizingContext(backingScaleProvider: { 2 })
        context.availableTotalHeightProvider = { 1055 }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 720),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(
            rootView: ViewportStabilityHarness(box: box, recorder: recorder, sizingContext: context)
        )
        window.contentView = hosting
        window.orderFrontRegardless()

        func sample() {
            hosting.layoutSubtreeIfNeeded()
            recorder.record(height: hosting.fittingSize.height)
        }

        try await tick(0.05)
        sample()

        for panel in [MenuPanel.tokenUsage, .keepAwake, .providerSwitch, .clipboard, .systemMonitor] {
            box.panel = panel
            try await tick(0.03)
            sample()
            try await tick(0.35) // 转场 + 改高 + 淡入完成
            sample()
        }
        // 稳定后 500ms 无补跳（A4 部分）。
        try await tick(0.5)
        sample()

        // A1 核心：切到已知短页（合成内容 120pt），settle 后总高必须等于
        // chrome(44+36) + 120（自适应收缩生效的直接证据）。
        box.panel = .clipboard
        try await tick(0.8)
        sample()
        let heights2 = recorder.samples.map(\.totalHeight)
        XCTAssertEqual(heights2.last ?? 0, 44 + 36 + 120, accuracy: 1.0, "短页收缩到自然高度，实测末值 \(heights2.last ?? -1)")

        // 每个淡出窗口内部高度恒定（≤0.5pt，SPEC §8「淡出期间恒定」）。
        for (index, windowHeights) in recorder.heightsPerExitWindow().enumerated() {
            guard !windowHeights.isEmpty else { continue }
            let delta = (windowHeights.max() ?? 0) - (windowHeights.min() ?? 0)
            XCTAssertLessThanOrEqual(
                delta, 0.5,
                "第 \(index) 个淡出窗口内高度漂移 ≤0.5pt，实测 \(windowHeights)"
            )
        }
        // 全序列内相邻采样不得大幅反向（改高段连续单调的粗粒度验证：
        // 相邻两次采样间隔内高度变化方向交替且幅度 >100pt 视为回弹）。
        let heights = recorder.samples.map(\.totalHeight)
        for i in 2..<heights.count {
            let d1 = heights[i - 1] - heights[i - 2]
            let d2 = heights[i] - heights[i - 1]
            if abs(d1) > 100, abs(d2) > 100, d1 * d2 < 0 {
                XCTFail("高度大幅反向回弹：\(heights)")
                break
            }
        }
        // 稳定后总高受上限约束。
        XCTAssertLessThanOrEqual(heights.last ?? 0, 690.5, "总高 ≤ chrome + 580")
    }

    private func tick(_ duration: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
}

@MainActor
final class PanelRouteBox: ObservableObject {
    @Published var panel: MenuPanel

    init(panel: MenuPanel) {
        self.panel = panel
    }
}

/// 壳层结构 harness：导航行 + 自适应 viewport Host + footer（与真实容器同构），
/// 经尺寸上下文接线转场屏障与稳定结构变化。
private struct ViewportStabilityHarness: View {
    @ObservedObject var box: PanelRouteBox
    @ObservedObject var recorder: ControlCenterViewportStabilityTests.Recorder
    @ObservedObject var sizingContext: ControlCenterSizingContext

    var body: some View {
        VStack(spacing: 0) {
            Text("Navigation")
                .frame(height: 44)
            PageSwitchHost(
                requestedRoute: box.panel,
                semantics: { _, _ in .peer },
                surface: { _ in .clear },
                onPhaseEvent: { event in
                    switch event {
                    case .exitStarted: recorder.event("exitStarted")
                    case .routeSwapped: recorder.event("routeSwapped")
                    case .mountPrepared: recorder.event("mountPrepared")
                    case .enterCompleted: recorder.event("enterCompleted")
                    }
                },
                onRouteMountedBarrier: { panel, proceed in
                    sizingContext.mountStarted(path: "harness/\(panel.rawValue)", proceed: proceed)
                }
            ) { panel in
                ScrollView(showsIndicators: false) {
                    // 合成内容高度按面板区分（短/长页交替）。
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: naturalHeight(for: panel))
                        .frame(maxWidth: .infinity)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(key: HarnessNaturalHeightKey.self, value: geo.size.height)
                            }
                        )
                }
                .frame(height: sizingContext.viewportHeight)
                .opacity(sizingContext.contentOpacity)
            }
            .clipped()
            Text("Footer")
                .frame(height: 36)
        }
        .frame(width: ControlCenterContentMetrics.panelWidth)
        .onPreferenceChange(HarnessNaturalHeightKey.self) { height in
            sizingContext.reportNaturalHeight(max(height, 1), isEmptyState: false)
        }
        .onAppear { sizingContext.reportShellHeight(44 + 36) }
    }

    private func naturalHeight(for panel: MenuPanel) -> CGFloat {
        switch panel {
        case .systemMonitor: 560
        case .tokenUsage: 900
        case .keepAwake: 200
        case .clipboard: 120
        case .providerSwitch: 400
        }
    }
}

private struct HarnessNaturalHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 真实容器自适应（SPEC §8 新契约）：挂载真实 ControlCenterContainerView，
/// 五个主面板切换完成后外壳总高等于目标（≤ chrome+580），且切换后
/// 500ms 内不再变化（无补跳）。
@MainActor
final class ControlCenterShellSizeStabilityTests: XCTestCase {
    func test_shellIntrinsicSize_settlesToAdaptiveTarget_noLateJump() async throws {
        // 五个功能全部置为可用，保证五个主页面都渲染真实内容分支。
        let availabilityKeys = AppFeature.allCases.map(\.availabilityKey)
        var originals: [String: Any?] = [:]
        for key in availabilityKeys where UserDefaults.standard.object(forKey: key) != nil {
            originals[key] = UserDefaults.standard.object(forKey: key)
        }
        let panelKey = UserDefaultsKeys.lastControlCenterPanel
        let originalPanel = UserDefaults.standard.object(forKey: panelKey)
        for feature in AppFeature.allCases {
            UserDefaults.standard.set(true, forKey: feature.availabilityKey)
        }
        defer {
            for (key, value) in originals {
                UserDefaults.standard.set(value, forKey: key)
            }
            for feature in AppFeature.allCases where originals[feature.availabilityKey] == nil {
                UserDefaults.standard.removeObject(forKey: feature.availabilityKey)
            }
            if let originalPanel {
                UserDefaults.standard.set(originalPanel, forKey: panelKey)
            } else {
                UserDefaults.standard.removeObject(forKey: panelKey)
            }
        }

        let state = makeStateForObservation()
        let context = ControlCenterSizingContext(backingScaleProvider: { 2 })
        context.availableTotalHeightProvider = { 1055 }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 720),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(
            rootView: ControlCenterContainerView(state: state, sizingContext: context)
        )
        window.contentView = hosting
        window.orderFrontRegardless()

        func currentHeight() -> CGFloat {
            hosting.layoutSubtreeIfNeeded()
            return hosting.fittingSize.height
        }

        try await tick(0.4) // 首次布局 + 测量链路收敛
        let initial = currentHeight()

        var settledHeights: [CGFloat] = []
        for panel in [MenuPanel.tokenUsage, .keepAwake, .providerSwitch, .clipboard, .systemMonitor] {
            UserDefaults.standard.set(panel.rawValue, forKey: panelKey)
            hosting.needsLayout = true
            try await tick(0.6) // 转场 + 改高 + 淡入 + 稳定
            let h = currentHeight()
            print("[shell-adaptive] \(panel.rawValue): \(h)")
            settledHeights.append(h)
        }
        // 稳定后 500ms 无补跳（A4）：最后面板再采样。
        try await tick(0.5)
        let finalHeight = currentHeight()
        XCTAssertEqual(finalHeight, settledHeights.last ?? -1, accuracy: 0.5, "稳定后 500ms 内不得补跳")

        // 全部面板总高受上限约束（chrome + 580）。
        for h in settledHeights {
            XCTAssertLessThanOrEqual(h, 705, "总高 \(h) 超出 chrome+viewport 上限")
        }
        // 自适应生效证据：面板间高度分化（不再全程固定 chrome+580）。
        let distinct = Set(settledHeights.map { ($0 / 5).rounded() })
        XCTAssertGreaterThan(distinct.count, 1, "各面板应按自然高度分化，实测 \(settledHeights)")
        XCTAssertLessThan(settledHeights.min() ?? 0, 500, "存在短页收缩（实测 \(settledHeights)）")
        _ = initial
    }

    private func tick(_ duration: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
}
