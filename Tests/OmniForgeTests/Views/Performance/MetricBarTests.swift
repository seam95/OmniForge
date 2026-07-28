import XCTest
import SwiftUI
@testable import OmniForge

final class MetricBarTests: XCTestCase {
    func test_clamp_boundsValueToUnitInterval() {
        XCTAssertEqual(MetricBar.clamp(-0.5), 0)
        XCTAssertEqual(MetricBar.clamp(0), 0)
        XCTAssertEqual(MetricBar.clamp(0.42), 0.42)
        XCTAssertEqual(MetricBar.clamp(1), 1)
        XCTAssertEqual(MetricBar.clamp(1.5), 1)
    }

    func test_resolvedColor_defaultPathUsesGreenOrangeRed() {
        XCTAssertEqual(
            MetricBar.resolvedColor(percent: 10, warning: 60, critical: 80, tint: nil),
            Color.green
        )
        XCTAssertEqual(
            MetricBar.resolvedColor(percent: 60, warning: 60, critical: 80, tint: nil),
            Color.orange
        )
        XCTAssertEqual(
            MetricBar.resolvedColor(percent: 80, warning: 60, critical: 80, tint: nil),
            Color.red
        )
    }

    func test_resolvedColor_tintModeOverridesNormalOnly() {
        let tint = Color.blue
        XCTAssertEqual(
            MetricBar.resolvedColor(percent: 20, warning: 60, critical: 80, tint: tint),
            tint
        )
        XCTAssertEqual(
            MetricBar.resolvedColor(percent: 65, warning: 60, critical: 80, tint: tint),
            Color.orange
        )
        XCTAssertEqual(
            MetricBar.resolvedColor(percent: 90, warning: 60, critical: 80, tint: tint),
            Color.red
        )
    }

    func test_barTint_clampsProgressBeforeThresholds() {
        // progress 0.9 → 90% → critical red regardless of card accent
        XCTAssertEqual(
            MonitorCardAccent.barTint(for: .cpu, progress: 0.9),
            Color.red
        )
        // progress 0.5 → 50% → card accent (cpu = accentColor)
        XCTAssertEqual(
            MonitorCardAccent.barTint(for: .cpu, progress: 0.5),
            Color.accentColor
        )
        // out-of-range high still clamps then critical
        XCTAssertEqual(
            MonitorCardAccent.barTint(for: .memory, progress: 2.0),
            Color.red
        )
        // negative clamps to 0 → normal accent (memory teal)
        XCTAssertEqual(
            MonitorCardAccent.barTint(for: .memory, progress: -1),
            MonitorCardAccent.color(for: .memory)
        )
    }
}
