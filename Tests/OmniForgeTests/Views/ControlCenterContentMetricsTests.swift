import XCTest
@testable import OmniForge

final class ControlCenterContentMetricsTests: XCTestCase {
    func test_metrics_matchControlCenterShellContract() {
        XCTAssertEqual(ControlCenterContentMetrics.panelWidth, 380)
        XCTAssertEqual(ControlCenterContentMetrics.maxContentHeight, 525)
        XCTAssertEqual(ControlCenterContentMetrics.emptyContentMinHeight, 120)
    }

    func test_usesSelfSizedFixedHeight_allPanelsAdaptive() {
        XCTAssertFalse(ControlCenterContentMetrics.usesSelfSizedFixedHeight(.systemMonitor))
        XCTAssertFalse(ControlCenterContentMetrics.usesSelfSizedFixedHeight(.keepAwake))
        XCTAssertFalse(ControlCenterContentMetrics.usesSelfSizedFixedHeight(.clipboard))
    }

    func test_resolvedHeight_capsAtMaxAndIgnoresInvalid() {
        XCTAssertEqual(
            ControlCenterContentMetrics.resolvedHeight(contentHeight: 240, maxHeight: 525),
            240
        )
        XCTAssertEqual(
            ControlCenterContentMetrics.resolvedHeight(contentHeight: 600, maxHeight: 525),
            525
        )
        XCTAssertEqual(
            ControlCenterContentMetrics.resolvedHeight(contentHeight: 525, maxHeight: 525),
            525
        )
        XCTAssertEqual(
            ControlCenterContentMetrics.resolvedHeight(contentHeight: 0, maxHeight: 520),
            0
        )
        XCTAssertEqual(
            ControlCenterContentMetrics.resolvedHeight(contentHeight: -10, maxHeight: 520),
            0
        )
        XCTAssertEqual(
            ControlCenterContentMetrics.resolvedHeight(contentHeight: .nan, maxHeight: 520),
            0
        )
    }
}
