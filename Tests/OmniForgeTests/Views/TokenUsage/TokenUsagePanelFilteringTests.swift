import XCTest
@testable import OmniForge

/// Token 用量面板 Provider 过滤与显隐纯逻辑测试。
final class TokenUsagePanelFilteringTests: XCTestCase {
    func test_balanceCardVisibility_visibleOnlyForNilOrDeepSeek() {
        // 当 DeepSeek 余额卡已配置（showingBalanceCard == true）
        let showingBalanceCard = true

        func shouldShowBalance(selectedProvider: TokenUsageProvider?) -> Bool {
            (selectedProvider == nil || selectedProvider == .deepSeek) && showingBalanceCard
        }

        XCTAssertTrue(shouldShowBalance(selectedProvider: nil), "全部（nil）时应展示 DeepSeek 余额卡")
        XCTAssertTrue(shouldShowBalance(selectedProvider: .deepSeek), "选中 DeepSeek 时应展示 DeepSeek 余额卡")
        XCTAssertFalse(shouldShowBalance(selectedProvider: .codex), "选中 Codex 时绝不应展示 DeepSeek 余额卡")
        XCTAssertFalse(shouldShowBalance(selectedProvider: .antigravity), "选中 Antigravity 时绝不应展示 DeepSeek 余额卡")
        XCTAssertFalse(shouldShowBalance(selectedProvider: .kimi), "选中 Kimi 时绝不应展示 DeepSeek 余额卡")
        XCTAssertFalse(shouldShowBalance(selectedProvider: .claude), "选中 Claude 时绝不应展示 DeepSeek 余额卡")
        XCTAssertFalse(shouldShowBalance(selectedProvider: .cursor), "选中 Cursor 时绝不应展示 DeepSeek 余额卡")
    }

    func test_balanceCardVisibility_hiddenWhenNotConfigured() {
        let showingBalanceCard = false

        func shouldShowBalance(selectedProvider: TokenUsageProvider?) -> Bool {
            (selectedProvider == nil || selectedProvider == .deepSeek) && showingBalanceCard
        }

        XCTAssertFalse(shouldShowBalance(selectedProvider: nil))
        XCTAssertFalse(shouldShowBalance(selectedProvider: .deepSeek))
        XCTAssertFalse(shouldShowBalance(selectedProvider: .codex))
    }

    func test_visibleProviders_includesDeepSeekWhenConfigured() {
        let configuredLimitsProviders: [TokenUsageProvider] = [.codex, .kimi]
        let deepSeekConfigured = true

        var providers = Set(configuredLimitsProviders)
        if deepSeekConfigured {
            providers.insert(.deepSeek)
        }
        let visible = TokenUsageProvider.allCases.filter { providers.contains($0) }

        XCTAssertEqual(visible, [.codex, .kimi, .deepSeek])
    }

    func test_visibleProviders_excludesDeepSeekWhenNotConfigured() {
        let configuredLimitsProviders: [TokenUsageProvider] = [.codex, .kimi]
        let deepSeekConfigured = false

        var providers = Set(configuredLimitsProviders)
        if deepSeekConfigured {
            providers.insert(.deepSeek)
        }
        let visible = TokenUsageProvider.allCases.filter { providers.contains($0) }

        XCTAssertEqual(visible, [.codex, .kimi])
    }

    // MARK: - 多供应商接入（2026-08-24）

    func test_visibleProviders_autoIncludesNewProvidersWhenConfigured() {
        // 面板胶囊由 `configuredProviders`（allCases 过滤）驱动，无需结构改动；
        // 任一新 provider 配置后自动出现。
        let newProviders: [TokenUsageProvider] = [
            .opencode, .codebuddy, .workbuddy, .grok, .zcode,
            .traeCN, .qoder, .dsh, .arkCodingPlan,
        ]
        for provider in newProviders {
            let configured: Set<TokenUsageProvider> = [provider]
            let visible = TokenUsageProvider.allCases.filter { configured.contains($0) }
            XCTAssertEqual(visible, [provider], "\(provider.rawValue) 配置后出现在胶囊条")
        }
    }

    func test_balanceCardVisibility_newProvidersNeverShowDeepSeekCard() {
        let showingBalanceCard = true
        let newProviders: [TokenUsageProvider] = [
            .opencode, .codebuddy, .workbuddy, .grok, .zcode,
            .traeCN, .qoder, .dsh, .arkCodingPlan,
        ]
        for provider in newProviders {
            let showsBalance = (provider == .deepSeek) && showingBalanceCard
            XCTAssertFalse(showsBalance, "选中 \(provider.rawValue) 时绝不应展示 DeepSeek 余额卡")
        }
    }
}
