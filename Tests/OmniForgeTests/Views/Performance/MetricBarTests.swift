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
            Theme.Stats.statusNormal
        )
        XCTAssertEqual(
            MetricBar.resolvedColor(percent: 60, warning: 60, critical: 80, tint: nil),
            Theme.Stats.ram
        )
        XCTAssertEqual(
            MetricBar.resolvedColor(percent: 80, warning: 60, critical: 80, tint: nil),
            Theme.Stats.up
        )
    }

    func test_resolvedColor_tintModeOverridesNormalOnly() {
        let tint = Theme.Stats.cpu
        XCTAssertEqual(
            MetricBar.resolvedColor(percent: 20, warning: 60, critical: 80, tint: tint),
            tint
        )
        XCTAssertEqual(
            MetricBar.resolvedColor(percent: 65, warning: 60, critical: 80, tint: tint),
            Theme.Stats.ram
        )
        XCTAssertEqual(
            MetricBar.resolvedColor(percent: 90, warning: 60, critical: 80, tint: tint),
            Theme.Stats.up
        )
    }

    func test_barTint_fixedColorExceptBatteryThresholds() {
        // 重构后：卡内可视化统一固定色，仅电池保留低电量红/橙
        XCTAssertEqual(
            MonitorCardAccent.barTint(for: .cpu, progress: 0.9),
            MonitorCardAccent.color(for: .cpu)
        )
        XCTAssertEqual(
            MonitorCardAccent.barTint(for: .cpu, progress: 0.5),
            MonitorCardAccent.color(for: .cpu)
        )
        // 越界高仍被钳制，但颜色不变（不再转红）
        XCTAssertEqual(
            MonitorCardAccent.barTint(for: .memory, progress: 2.0),
            MonitorCardAccent.color(for: .memory)
        )
        XCTAssertEqual(
            MonitorCardAccent.barTint(for: .memory, progress: -1),
            MonitorCardAccent.color(for: .memory)
        )
        // 电池：低电量红 / 中低橙 / 正常绿
        XCTAssertEqual(
            MonitorCardAccent.barTint(for: .battery, progress: 0.10),
            Theme.Stats.up
        )
        XCTAssertEqual(
            MonitorCardAccent.barTint(for: .battery, progress: 0.30),
            Theme.Stats.ram
        )
        XCTAssertEqual(
            MonitorCardAccent.barTint(for: .battery, progress: 0.60),
            Theme.Stats.down
        )
    }
}
