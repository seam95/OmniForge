import XCTest
import SwiftUI
@testable import OmniForge

/// 限额卡行内纯逻辑测试（#11 视觉修复）：
/// - 进度条进度固定按 usedPercent 并在 [0, 1] 钳制；
/// - 行内数值按 displayMode 切换已用 / 剩余，额度窗固定显示剩余货币；
/// - MetricBar 状态色按 usedPercent 染色（remaining 模式下消耗进度与颜色同向自洽）。
final class TokenUsageLimitRowTests: XCTestCase {
    private let strings = Strings.zhHans

    private func makeWindow(usedPercent: Double, remaining: Double? = nil, unit: String? = nil) -> UsageWindow {
        UsageWindow(
            usedPercent: usedPercent,
            resetAt: nil,
            limit: nil,
            used: nil,
            remaining: remaining,
            unit: unit,
            windowSeconds: nil
        )
    }

    func test_limitBarProgress_clampedToUnitInterval() {
        XCTAssertEqual(
            TokenUsageFormat.limitBarProgress(for: makeWindow(usedPercent: 0)),
            0.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TokenUsageFormat.limitBarProgress(for: makeWindow(usedPercent: 75.5)),
            0.755,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TokenUsageFormat.limitBarProgress(for: makeWindow(usedPercent: 120)),
            1.0,
            accuracy: 0.0001,
            "超量用量钳制在 1.0"
        )
        XCTAssertEqual(
            TokenUsageFormat.limitBarProgress(for: makeWindow(usedPercent: -10)),
            0.0,
            accuracy: 0.0001,
            "负数用量钳制在 0.0"
        )
    }

    func test_limitValueText_usedMode_displaysUsedPercent() {
        let window = makeWindow(usedPercent: 75.4)
        let text = TokenUsageFormat.limitValueText(
            kind: .session,
            window: window,
            displayMode: .used,
            strings: strings
        )
        XCTAssertEqual(text, "75%")
    }

    func test_limitValueText_remainingMode_displaysRemainingPercent() {
        let window1 = makeWindow(usedPercent: 1.0)
        XCTAssertEqual(
            TokenUsageFormat.limitValueText(kind: .weekly, window: window1, displayMode: .remaining, strings: strings),
            "99%",
            "已用 1% 在 remaining 模式下显示 99%"
        )

        let window2 = makeWindow(usedPercent: 75.4)
        XCTAssertEqual(
            TokenUsageFormat.limitValueText(kind: .session, window: window2, displayMode: .remaining, strings: strings),
            "25%",
            "已用 75.4% 在 remaining 模式下显示 25%"
        )

        let window3 = makeWindow(usedPercent: 105.0)
        XCTAssertEqual(
            TokenUsageFormat.limitValueText(kind: .monthly, window: window3, displayMode: .remaining, strings: strings),
            "0%",
            "超限在 remaining 模式下不出现负数"
        )
    }

    func test_limitValueText_creditsWindow_alwaysDisplaysRemainingCurrency() {
        let usdWindow = makeWindow(usedPercent: 50.0, remaining: 12.3456, unit: "USD")
        XCTAssertEqual(
            TokenUsageFormat.limitValueText(kind: .credits, window: usdWindow, displayMode: .used, strings: strings),
            "剩 $12.35",
            "额度窗固定显示剩余货币"
        )
        XCTAssertEqual(
            TokenUsageFormat.limitValueText(kind: .credits, window: usdWindow, displayMode: .remaining, strings: strings),
            "剩 $12.35",
            "额度窗在 remaining 模式下也保持剩余货币口径"
        )

        let cnyWindow = makeWindow(usedPercent: 50.0, remaining: 50.0, unit: "CNY")
        XCTAssertEqual(
            TokenUsageFormat.limitValueText(kind: .credits, window: cnyWindow, displayMode: .used, strings: strings),
            "剩 CNY 50.00"
        )
    }

    func test_currencyPrefix() {
        XCTAssertEqual(TokenUsageFormat.currencyPrefix(for: "USD"), "$")
        XCTAssertEqual(TokenUsageFormat.currencyPrefix(for: "usd"), "$")
        XCTAssertEqual(TokenUsageFormat.currencyPrefix(for: nil), "$")
        XCTAssertEqual(TokenUsageFormat.currencyPrefix(for: "EUR"), "EUR ")
        XCTAssertEqual(TokenUsageFormat.currencyPrefix(for: "CNY"), "CNY ")
    }

    func test_barColorConsistentWithUsedPercentageInRemainingMode() {
        // 场景 1：Cursor 本月窗口已用 1%（remaining 模式下用户看到 99%）
        let progress1 = TokenUsageFormat.limitBarProgress(for: makeWindow(usedPercent: 1.0))
        let color1 = MetricBar.resolvedColor(
            percent: progress1 * 100,
            warning: 70,
            critical: 90,
            tint: Theme.Stats.statusNormal
        )
        XCTAssertEqual(color1, Theme.Stats.statusNormal, "已用 1% 时条为正常绿色，不因剩余模式数值 99% 误判为告警")

        // 场景 2：已用 95%（remaining 模式下用户看到 5% 剩余，濒临用尽）
        let progress2 = TokenUsageFormat.limitBarProgress(for: makeWindow(usedPercent: 95.0))
        let color2 = MetricBar.resolvedColor(
            percent: progress2 * 100,
            warning: 70,
            critical: 90,
            tint: Theme.Stats.statusNormal
        )
        XCTAssertEqual(color2, Theme.Stats.up, "已用 95% 时条为红色危险态，与剩余模式数值 5%（快用完）语义同向自洽")

        // 场景 3：已用 75%（remaining 模式下用户看到 25% 剩余）
        let progress3 = TokenUsageFormat.limitBarProgress(for: makeWindow(usedPercent: 75.0))
        let color3 = MetricBar.resolvedColor(
            percent: progress3 * 100,
            warning: 70,
            critical: 90,
            tint: Theme.Stats.statusNormal
        )
        XCTAssertEqual(color3, Theme.Stats.ram, "已用 75% 时条为橙色预警态")
    }
}
