import XCTest
@testable import OmniForge

/// 提供商设置行状态装配（#10）：登录态/套餐/未配置引导的纯逻辑。
final class TokenUsageProviderStatusTests: XCTestCase {
    private let strings = Strings.zhHans

    func test_statusText_configuredWithPlan_assemblesPlanAndSignedInMarker() {
        let limits = makeLimits(planLabel: "Pro")
        XCTAssertEqual(
            TokenUsageProviderStatusBuilder.statusText(limits: limits, strings: strings),
            "Pro · ✓ " + strings.tokenSettingsLoggedIn
        )
    }

    func test_statusText_configuredWithoutPlan_showsSignedInMarkerOnly() {
        let limits = makeLimits(planLabel: nil)
        XCTAssertEqual(
            TokenUsageProviderStatusBuilder.statusText(limits: limits, strings: strings),
            "✓ " + strings.tokenSettingsLoggedIn
        )
    }

    func test_statusText_notConfigured_assemblesNotSignedInAndGuide() {
        let limits = ProviderUsageLimits.notConfigured(.claude)
        XCTAssertEqual(
            TokenUsageProviderStatusBuilder.statusText(limits: limits, strings: strings),
            String(
                format: strings.tokenSettingsProviderStatusFormat,
                strings.tokenSettingsNotConfigured,
                strings.tokenSettingsHowToConfigure
            )
        )
    }

    func test_statusText_reauthRequired_showsReauthLabel() {
        var limits = makeLimits(planLabel: "Pro")
        limits.issue = .reauthRequired
        XCTAssertEqual(
            TokenUsageProviderStatusBuilder.statusText(limits: limits, strings: strings),
            strings.tokenStatusReauth
        )
    }

    func test_statusText_noSnapshot_yieldsNil() {
        XCTAssertNil(TokenUsageProviderStatusBuilder.statusText(limits: nil, strings: strings))
    }

    func test_showsConfigureGuide_onlyForNotConfigured() {
        XCTAssertTrue(TokenUsageProviderStatusBuilder.showsConfigureGuide(
            ProviderUsageLimits.notConfigured(.codex)
        ))
        XCTAssertFalse(TokenUsageProviderStatusBuilder.showsConfigureGuide(makeLimits(planLabel: nil)))
        XCTAssertFalse(TokenUsageProviderStatusBuilder.showsConfigureGuide(nil))
    }

    func test_configureHint_injectsProviderCliCommand() {
        XCTAssertEqual(
            TokenUsageProviderStatusBuilder.configureHint(for: .claude, strings: strings),
            String(format: strings.tokenSettingsConfigureHintFormat, "claude")
        )
    }

    func test_configureHint_cursorUsesAppLoginCopy() {
        XCTAssertEqual(
            TokenUsageProviderStatusBuilder.configureHint(for: .cursor, strings: strings),
            strings.tokenSettingsConfigureHintCursor
        )
    }

    func test_configureHint_deepSeekUsesApiKeyCaption() {
        XCTAssertEqual(
            TokenUsageProviderStatusBuilder.configureHint(for: .deepSeek, strings: strings),
            strings.deepSeekSettingsApiKeyCaption
        )
    }

    func test_deepSeekProvider_properties() {
        XCTAssertEqual(TokenUsageProvider.deepSeek.rawValue, "deepseek")
        XCTAssertEqual(TokenUsageProvider.deepSeek.displayName, "DeepSeek")
        XCTAssertEqual(TokenUsageProvider.deepSeek.setupCLICommand, "")
        XCTAssertEqual(TokenUsageProvider.deepSeek.accentColor, DeepSeekBalanceCardView.brandColor)
    }

    private func makeLimits(planLabel: String?) -> ProviderUsageLimits {
        ProviderUsageLimits(
            provider: .claude,
            configured: true,
            subscriptionStatus: .active,
            planLabel: planLabel,
            windows: [:],
            confidence: .official,
            capturedAt: Date(),
            stale: false,
            issue: nil
        )
    }
}
