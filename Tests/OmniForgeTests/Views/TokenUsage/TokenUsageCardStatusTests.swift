import XCTest
@testable import OmniForge

/// TokenUsageCardStatus 派生 — stale / 429 冷却 / reauth 的徽章区分。
final class TokenUsageCardStatusTests: XCTestCase {
    private func snapshot(
        issue: LimitError? = nil,
        stale: Bool = false,
        windows: [LimitWindowKind: UsageWindow] = [:]
    ) -> ProviderUsageLimits {
        ProviderUsageLimits(
            provider: .claude,
            configured: true,
            subscriptionStatus: .active,
            planLabel: nil,
            windows: windows,
            confidence: .official,
            capturedAt: Date(),
            stale: stale,
            issue: issue
        )
    }

    private func sessionWindow(percent: Double = 50) -> [LimitWindowKind: UsageWindow] {
        [.session: UsageWindow(
            usedPercent: percent,
            resetAt: Date().addingTimeInterval(3600),
            limit: nil,
            used: nil,
            remaining: nil,
            unit: nil,
            windowSeconds: 18000
        )]
    }

    func test_derive_thresholdBoundariesUseInclusiveComparison() {
        // 与 MetricBar（>= warning/critical）和告警（>= 85）口径一致：恰好 85/70 即升级。
        XCTAssertEqual(
            TokenUsageCardStatus.derive(from: snapshot(windows: sessionWindow(percent: 85))),
            .exceeded
        )
        XCTAssertEqual(
            TokenUsageCardStatus.derive(from: snapshot(windows: sessionWindow(percent: 84.9))),
            .approaching
        )
        XCTAssertEqual(
            TokenUsageCardStatus.derive(from: snapshot(windows: sessionWindow(percent: 70))),
            .approaching
        )
        XCTAssertEqual(
            TokenUsageCardStatus.derive(from: snapshot(windows: sessionWindow(percent: 69.9))),
            .normal
        )
    }

    func test_derive_staleLastGoodWithNetworkIssue_isStale() {
        let status = TokenUsageCardStatus.derive(from: snapshot(
            issue: .network("offline"),
            stale: true,
            windows: sessionWindow()
        ))
        XCTAssertEqual(status, .stale, "显示 last-good 快照 + 网络错误 → 标数据可能过期")
    }

    func test_derive_networkErrorWithoutLastGood_isTransient() {
        let status = TokenUsageCardStatus.derive(from: snapshot(issue: .network("offline"), stale: true))
        XCTAssertEqual(status, .transient)
    }

    func test_derive_rateLimited_isRateLimitedEvenWhenStale() {
        let status = TokenUsageCardStatus.derive(from: snapshot(
            issue: .rateLimited(retryAt: Date().addingTimeInterval(300)),
            stale: true,
            windows: sessionWindow()
        ))
        XCTAssertEqual(status, .rateLimited, "冷却倒计时优先于 stale 徽章")
    }

    func test_derive_reauth_isReauth() {
        let status = TokenUsageCardStatus.derive(from: snapshot(
            issue: .reauthRequired,
            stale: true,
            windows: sessionWindow()
        ))
        XCTAssertEqual(status, .reauth)
    }
}
