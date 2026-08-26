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

    func test_visibleProviders_respectsCustomProviderOrder() {
        let configuredProviders: [TokenUsageProvider] = [.codex, .antigravity, .kimi]
        let deepSeekConfigured = true

        var providers = Set(configuredProviders)
        if deepSeekConfigured {
            providers.insert(.deepSeek)
        }

        // 自定义排序：DeepSeek 第一，Kimi 第二，Antigravity 第三，Codex 第四
        let customOrder: [TokenUsageProvider] = [.deepSeek, .kimi, .antigravity, .codex]
        let visible = customOrder.filter { providers.contains($0) }

        XCTAssertEqual(visible, [.deepSeek, .kimi, .antigravity, .codex])
    }

    func test_providerCards_orderedByCustomPreferences() {
        // 模拟已配置 provider 与自定义偏好顺序
        let customOrder: [TokenUsageProvider] = [.antigravity, .deepSeek, .codex]
        let configuredSet: Set<TokenUsageProvider> = [.codex, .deepSeek, .antigravity]

        let visibleProviders = customOrder.filter { configuredSet.contains($0) }
        XCTAssertEqual(visibleProviders, [.antigravity, .deepSeek, .codex])

        // 模拟「全部」时卡片列表顺序
        let selectedProvider: TokenUsageProvider? = nil
        let targetProviders = selectedProvider.map { [$0] } ?? visibleProviders
        XCTAssertEqual(targetProviders, [.antigravity, .deepSeek, .codex], "全部视图下卡片顺序与偏好设置严格一致")

        // 模拟单选时仅展示选中的 provider 卡片
        let singleSelect = TokenUsageProvider.deepSeek
        let singleTarget = [singleSelect]
        XCTAssertEqual(singleTarget, [.deepSeek])
    }

    // MARK: - 限额显示弹层（显隐过滤，2026-08-25）

    func test_visibleProviders_excludesHiddenProviders() {
        let configured: Set<TokenUsageProvider> = [.codex, .kimi, .claude]
        let hidden: Set<TokenUsageProvider> = [.kimi]

        let visible = TokenUsageProvider.allCases.filter { configured.contains($0) && !hidden.contains($0) }

        XCTAssertEqual(visible, [.claude, .codex], "隐藏的 kimi 从胶囊与卡片中剔除")
    }

    func test_popover_configuredProviders_includesDeepSeekWhenShowingBalance() {
        let limitsConfigured: [TokenUsageProvider] = [.codex, .kimi]
        let showingBalanceCard = true

        var providers = Set(limitsConfigured)
        if showingBalanceCard {
            providers.insert(.deepSeek)
        }
        let popoverList = TokenUsageProvider.allCases.filter { providers.contains($0) }

        XCTAssertEqual(popoverList, [.codex, .kimi, .deepSeek], "齿轮弹层包含显示中的 DeepSeek 余额提供商")
    }

    func test_visibleProviders_deepSeekCanBeHiddenViaPopover() {
        let configured: Set<TokenUsageProvider> = [.codex, .deepSeek]
        let hidden: Set<TokenUsageProvider> = [.deepSeek]

        let visible = TokenUsageProvider.allCases.filter { configured.contains($0) && !hidden.contains($0) }

        XCTAssertEqual(visible, [.codex], "DeepSeek 在弹层中被隐藏后从主面板过滤")
    }

    // MARK: - 供应商卡片分割线逻辑（2026-08-26）

    func test_displayableProviders_filtersAndDeterminesSeparators() {
        let visibleProviders: [TokenUsageProvider] = [.deepSeek, .codex, .kimi, .antigravity]
        let limits: [TokenUsageProvider: ProviderUsageLimits] = [
            .codex: ProviderUsageLimits(
                provider: .codex,
                configured: true,
                subscriptionStatus: .active,
                planLabel: "Plus",
                windows: [:],
                confidence: .official,
                capturedAt: Date(),
                stale: false,
                issue: nil
            ),
            .kimi: ProviderUsageLimits(
                provider: .kimi,
                configured: true,
                subscriptionStatus: .active,
                planLabel: nil,
                windows: [:],
                confidence: .official,
                capturedAt: Date(),
                stale: false,
                issue: nil
            ),
        ]
        let showingBalanceCard = true

        func displayable(from providers: [TokenUsageProvider]) -> [TokenUsageProvider] {
            providers.filter { provider in
                (limits[provider] != nil) || (provider == .deepSeek && showingBalanceCard)
            }
        }

        // 全部视图：deepSeek, codex, kimi 有有效卡片；antigravity 无数据被过滤
        let active = displayable(from: visibleProviders)
        XCTAssertEqual(active, [.deepSeek, .codex, .kimi])

        // 分割线条件：大于 0 索引处插入分割线
        let separatorIndices = active.enumerated().compactMap { index, _ in index > 0 ? index : nil }
        XCTAssertEqual(separatorIndices, [1, 2], "3 个供应商卡片之间应有 2 条分割线")

        // 单选 Codex 时：仅展示 1 个卡片，无分割线
        let singleSelectActive = displayable(from: [.codex])
        XCTAssertEqual(singleSelectActive, [.codex])
        let singleSeparators = singleSelectActive.enumerated().compactMap { index, _ in index > 0 ? index : nil }
        XCTAssertTrue(singleSeparators.isEmpty, "单个供应商卡片不应有分割线")
    }
}


