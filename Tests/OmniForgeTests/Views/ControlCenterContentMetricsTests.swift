import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// 控制中心壳层尺寸契约（SPEC §8.1）：固定宽度与 viewport，切换期间尺寸稳定。
final class ControlCenterContentMetricsTests: XCTestCase {
    func test_metrics_matchControlCenterShellContract() {
        XCTAssertEqual(ControlCenterContentMetrics.panelWidth, 380)
        XCTAssertEqual(ControlCenterContentMetrics.viewportHeight, 580)
        XCTAssertEqual(ControlCenterContentMetrics.emptyContentMinHeight, 120)
    }
}

/// 程序化 viewport 稳定性检查（PLAN 阶段 2.8）：页面切换（含转场中点）期间
/// 内容 viewport 高度偏差不超过 0.5pt。壳层以固定 `frame(height:)` 承载
/// PageSwitchHost，尺寸与 route 无关；本测试覆盖五个主页面轮换切换全程。
@MainActor
final class ControlCenterViewportStabilityTests: XCTestCase {
    func test_viewportHeight_stableAcrossPanelSwitches() async throws {
        let box = PanelRouteBox(panel: .systemMonitor)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 720),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(
            rootView: ViewportStabilityHarness(box: box)
        )
        window.contentView = hosting
        window.orderFrontRegardless()

        var heights: [CGFloat] = []
        func sample() {
            hosting.layoutSubtreeIfNeeded()
            let probe = hosting.frame(for: .viewportProbe)
            if let probe, probe.height > 0 {
                heights.append(probe.height)
            }
        }

        try await tick(0.05)
        sample()

        let panels: [MenuPanel] = [.tokenUsage, .keepAwake, .providerSwitch, .clipboard, .systemMonitor]
        for panel in panels {
            box.panel = panel
            try await tick(0.03) // 转场窗口内采样
            sample()
            try await tick(0.2) // 转场完成后采样
            sample()
        }

        XCTAssertGreaterThan(heights.count, 10, "sanity：采样点覆盖全部切换")
        let peakDelta = (heights.max() ?? 0) - (heights.min() ?? 0)
        XCTAssertLessThanOrEqual(
            peakDelta, 0.5,
            "五个主页面两两切换全程 viewport 高度偏差 ≤ 0.5pt，实测 \(heights)"
        )
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

/// 壳层结构 harness：导航行 + 固定 viewport Host + footer（与真实容器同构的骨架）。
private struct ViewportStabilityHarness: View {
    @ObservedObject var box: PanelRouteBox

    var body: some View {
        VStack(spacing: 0) {
            Text("Navigation")
                .frame(height: 44)
            PageSwitchHost(
                requestedRoute: box.panel,
                semantics: { _, _ in .peer },
                surface: { _ in .clear }
            ) { panel in
                ScrollView(showsIndicators: false) {
                    Text("Panel \(panel.rawValue)")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 120)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: ControlCenterContentMetrics.viewportHeight)
            .clipped()
            .background(ViewportProbeRepresentable())
            Text("Footer")
                .frame(height: 36)
        }
        .frame(width: ControlCenterContentMetrics.panelWidth)
    }
}

/// viewport 高度探针：NSView.identifier 供宿主 frame 查询。
private struct ViewportProbeRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = .viewportProbe
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private extension NSUserInterfaceItemIdentifier {
    static let viewportProbe = NSUserInterfaceItemIdentifier(
        "ControlCenterViewportStabilityTests.viewportProbe"
    )
}

private extension NSView {
    /// 深度优先查找指定 identifier 的后代，返回其位于本视图坐标系内的 frame。
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
