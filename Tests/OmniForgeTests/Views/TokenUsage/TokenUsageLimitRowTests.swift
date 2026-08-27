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

    func test_windowResetTime_formatsSameDayAndDifferentDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)! // +08:00

        let baseComponents = DateComponents(year: 2026, month: 8, day: 24, hour: 10, minute: 0, second: 0)
        let now = calendar.date(from: baseComponents)!

        // 场景 1：同日重置（如 13:42）
        let sameDayComponents = DateComponents(year: 2026, month: 8, day: 24, hour: 13, minute: 42, second: 0)
        let sameDayDate = calendar.date(from: sameDayComponents)!
        let sameDayResult = TokenUsageFormat.windowResetTime(resetAt: sameDayDate, now: now, calendar: calendar)
        XCTAssertEqual(sameDayResult, "13:42", "同日重置显示 HH:mm")

        // 场景 2：跨日重置（如 7 天后，显示 7d）
        let diffDayComponents = DateComponents(year: 2026, month: 8, day: 31, hour: 16, minute: 42, second: 0)
        let diffDayDate = calendar.date(from: diffDayComponents)!
        let diffDayResult = TokenUsageFormat.windowResetTime(resetAt: diffDayDate, now: now, calendar: calendar)
        XCTAssertEqual(diffDayResult, "7d", "跨日重置显示 Xd")

        // 场景 3：已过期（resetAt <= now）
        let pastComponents = DateComponents(year: 2026, month: 8, day: 24, hour: 9, minute: 0, second: 0)
        let pastDate = calendar.date(from: pastComponents)!
        XCTAssertNil(TokenUsageFormat.windowResetTime(resetAt: pastDate, now: now, calendar: calendar), "已过期时间返回 nil")

        // 场景 4：nil 时间
        XCTAssertNil(TokenUsageFormat.windowResetTime(resetAt: nil, now: now, calendar: calendar), "nil 时间返回 nil")
    }

    func test_windowResetTimeTiered_boundaries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!

        let nowComponents = DateComponents(year: 2026, month: 8, day: 25, hour: 10, minute: 0, second: 0)
        let now = calendar.date(from: nowComponents)!

        // 场景 1：剩余 > 24h（如 6 天后） -> "6d"
        let date6d = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 10, minute: 0, second: 0))!
        XCTAssertEqual(TokenUsageFormat.windowResetTimeTiered(resetAt: date6d, now: now, calendar: calendar), "6d")

        // 场景 2：6h ≤ 剩余 ≤ 24h（如 12h 后） -> "12h"
        let date12h = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 22, minute: 0, second: 0))!
        XCTAssertEqual(TokenUsageFormat.windowResetTimeTiered(resetAt: date12h, now: now, calendar: calendar), "12h")

        // 场景 3：6h 边界 -> "6h"
        let date6h = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 16, minute: 0, second: 0))!
        XCTAssertEqual(TokenUsageFormat.windowResetTimeTiered(resetAt: date6h, now: now, calendar: calendar), "6h")

        // 场景 4：< 6h（如 4h 30m 后，即 14:30） -> "14:30"
        let date4h = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 14, minute: 30, second: 0))!
        XCTAssertEqual(TokenUsageFormat.windowResetTimeTiered(resetAt: date4h, now: now, calendar: calendar), "14:30")

        // 场景 5：已过期或 nil -> nil
        let past = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 9, minute: 0, second: 0))!
        XCTAssertNil(TokenUsageFormat.windowResetTimeTiered(resetAt: past, now: now, calendar: calendar))
        XCTAssertNil(TokenUsageFormat.windowResetTimeTiered(resetAt: nil, now: now, calendar: calendar))
    }

    func test_limitWindowKind_shortTitle() {
        XCTAssertEqual(LimitWindowKind.session.shortTitle(strings), "5h")
        XCTAssertEqual(LimitWindowKind.weekly.shortTitle(strings), "7d")
        XCTAssertEqual(LimitWindowKind.monthly.shortTitle(strings), "30d")
        XCTAssertEqual(LimitWindowKind.credits.shortTitle(strings), "额度")

        let enStrings = Strings.en
        XCTAssertEqual(LimitWindowKind.session.shortTitle(enStrings), "5h")
        XCTAssertEqual(LimitWindowKind.weekly.shortTitle(enStrings), "7d")
        XCTAssertEqual(LimitWindowKind.monthly.shortTitle(enStrings), "30d")
        XCTAssertEqual(LimitWindowKind.credits.shortTitle(enStrings), "Credits")

        // 无论何种 Provider，weekly 统一为 7d
        XCTAssertEqual(LimitWindowKind.weekly.shortTitle(for: .kimi, strings: strings), "7d")
        XCTAssertEqual(LimitWindowKind.weekly.shortTitle(for: .codex, strings: strings), "7d")
    }

    func test_differentDayTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let components = DateComponents(year: 2026, month: 9, day: 21, hour: 7, minute: 12, second: 0)
        let date = calendar.date(from: components)!
        XCTAssertEqual(TokenUsageFormat.differentDayTime(date), "9/21 07:12")
    }

    func test_limitBarStatusColor() {
        // Remaining 模式：低额度为危险红/警告橙，高额度为正常绿
        XCTAssertEqual(TokenUsageFormat.limitBarStatusColor(percent: 9, displayMode: .remaining), TokenUsageFormat.limitBarCriticalRed)
        XCTAssertEqual(TokenUsageFormat.limitBarStatusColor(percent: 20, displayMode: .remaining), TokenUsageFormat.limitBarWarningOrange)
        XCTAssertEqual(TokenUsageFormat.limitBarStatusColor(percent: 31, displayMode: .remaining), TokenUsageFormat.limitBarNormalGreen)
        XCTAssertEqual(TokenUsageFormat.limitBarStatusColor(percent: 98, displayMode: .remaining), TokenUsageFormat.limitBarNormalGreen)

        // Used 模式：高用量为危险红/警告橙，低用量为正常绿
        XCTAssertEqual(TokenUsageFormat.limitBarStatusColor(percent: 95, displayMode: .used), TokenUsageFormat.limitBarCriticalRed)
        XCTAssertEqual(TokenUsageFormat.limitBarStatusColor(percent: 75, displayMode: .used), TokenUsageFormat.limitBarWarningOrange)
        XCTAssertEqual(TokenUsageFormat.limitBarStatusColor(percent: 10, displayMode: .used), TokenUsageFormat.limitBarNormalGreen)
    }

    // MARK: - 窗口排列顺序

    func test_windowKindOrder_sessionBeforeWeekly() {
        let order = TokenUsageLimitCardView.windowKindOrder
        XCTAssertEqual(order, [.session, .weekly, .monthly, .credits], "5h 会话窗应排在 7d 周窗之前")
    }

    // MARK: - 重置权益行

    func test_resetLifetimeRemainingFraction() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        // grantedAt 缺失 -> 满寿命
        XCTAssertEqual(
            TokenUsageFormat.resetLifetimeRemainingFraction(
                grantedAt: nil,
                expiresAt: now.addingTimeInterval(3600),
                now: now
            ),
            1.0,
            accuracy: 0.0001
        )

        // 寿命过半 -> 0.5
        XCTAssertEqual(
            TokenUsageFormat.resetLifetimeRemainingFraction(
                grantedAt: now.addingTimeInterval(-3600),
                expiresAt: now.addingTimeInterval(3600),
                now: now
            ),
            0.5,
            accuracy: 0.0001
        )

        // 已过期 -> 0
        XCTAssertEqual(
            TokenUsageFormat.resetLifetimeRemainingFraction(
                grantedAt: now.addingTimeInterval(-7200),
                expiresAt: now.addingTimeInterval(-3600),
                now: now
            ),
            0.0,
            accuracy: 0.0001
        )

        // grantedAt 晚于 expiresAt（异常数据） -> 兜底满寿命
        XCTAssertEqual(
            TokenUsageFormat.resetLifetimeRemainingFraction(
                grantedAt: now.addingTimeInterval(3600),
                expiresAt: now,
                now: now
            ),
            1.0,
            accuracy: 0.0001
        )
    }

    func test_resetBankRowSpecs_labelsAndExpiry() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 10, minute: 0, second: 0))!
        let grantedAt = calendar.date(from: DateComponents(year: 2026, month: 8, day: 24, hour: 7, minute: 12, second: 0))!
        let expiresAt = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 7, minute: 12, second: 0))!

        let bank = UsageResetBank(
            availableCount: 2,
            totalEarnedCount: 2,
            credits: [
                UsageResetCreditEntry(grantedAt: grantedAt, expiresAt: expiresAt),
                UsageResetCreditEntry(grantedAt: nil, expiresAt: expiresAt.addingTimeInterval(86400)),
            ]
        )

        let specs = TokenUsageFormat.resetBankRowSpecs(resetBank: bank, now: now, strings: strings)
        XCTAssertEqual(specs.count, 2)
        XCTAssertEqual(specs[0].label, "重置 1")
        XCTAssertEqual(specs[1].label, "重置 2")
        XCTAssertEqual(specs[0].expiryText, "9/21 07:12")
        XCTAssertEqual(specs[0].helpText, "重置 1 · 9/21 07:12 过期")
        XCTAssertGreaterThan(specs[0].lifetimeRemaining, 0.9)
        XCTAssertEqual(specs[1].lifetimeRemaining, 1.0, accuracy: 0.0001, "grantedAt 缺失的权益按满寿命展示")

        let enSpecs = TokenUsageFormat.resetBankRowSpecs(resetBank: bank, now: now, strings: Strings.en)
        XCTAssertEqual(enSpecs[0].label, "Reset 1")
    }
}
