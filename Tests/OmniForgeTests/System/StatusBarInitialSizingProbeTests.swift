import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// 首显测高路径验证：离屏 hosting view + runloop 泵等待后，
/// 自然高度与 chrome 必须就绪且 commit 出自适应总高（非固定 580）。
/// 复刻 StatusBarController.installPopoverContentIfNeeded 的真实序列。
@MainActor
final class StatusBarInitialSizingProbeTests: XCTestCase {
    func test_offscreenPump_initialMeasurementReadyAndAdaptive() {
        let state = makeStateForObservation()
        let context = ControlCenterSizingContext(backingScaleProvider: { 2 })
        context.availableTotalHeightProvider = { 1055 }

        context.beginInitialMeasurement()
        let controller = NSHostingController(
            rootView: AnyView(
                ControlCenterContainerView(state: state, sizingContext: context)
            )
        )
        controller.sizingOptions = []
        let hostingView = controller.view
        hostingView.setFrameSize(
            NSSize(width: ControlCenterContentMetrics.panelWidth, height: 2000)
        )
        hostingView.layoutSubtreeIfNeeded()

        let waitDeadline = Date().addingTimeInterval(0.4)
        while !context.hasInitialMeasurement && Date() < waitDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertTrue(
            context.hasInitialMeasurement,
            "泵 runloop 后离屏测量必须就绪（onPreferenceChange 派发不依赖 window）"
        )
        let total = context.commitInitialMeasurement()
        // 监控页自然高度 < 580 上限 → 总高必须低于固定时代 675。
        XCTAssertLessThan(total, 675, "首显总高应按自然高度收缩，实测 \(total)")
        XCTAssertGreaterThan(total, 300)
    }
}
