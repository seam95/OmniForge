import XCTest
@testable import OmniForge

/// Token 用量面板 provider 展示候选、排序与显隐纯逻辑测试。
/// （面板已移除 provider 筛选胶囊，余额区固定展示全部已配置供应商。）
final class TokenUsagePanelFilteringTests: XCTestCase {
    func test_balanceCard_deepSeekIncludedInAllProvidersViewOnlyWhenConfigured() {
        // DeepSeek 余额卡仅在配置余额后随全部视图展示；未配置时不出现在卡片列表。
        let withBalance = TokenUsageProviderDisplayPolicy.displayableCardProviders(
            from: [.codex, .kimi, .deepSeek],
            limits: [:],
            credentialConfiguredProviders: [],
            showingDeepSeekBalance: true
        )
        XCTAssertEqual(withBalance, [.deepSeek], "配置余额后全部视图包含 DeepSeek")

        let withoutBalance = TokenUsageProviderDisplayPolicy.displayableCardProviders(
            from: [.codex, .kimi, .deepSeek],
            limits: [:],
            credentialConfiguredProviders: [],
            showingDeepSeekBalance: false
        )
        XCTAssertTrue(withoutBalance.isEmpty, "未配置余额时不展示 DeepSeek 卡")
    }

    func test_balanceCard_neverAttachedToNonDeepSeekProviders() {
        // 余额卡只归属 DeepSeek：其余 provider 出示限额快照也不引入余额卡。
        let displayable = TokenUsageProviderDisplayPolicy.displayableCardProviders(
            from: [.opencode, .codebuddy, .workbuddy, .grok, .zcode, .traeCN, .qoder, .dsh, .arkCodingPlan],
            limits: [:],
            credentialConfiguredProviders: [],
            showingDeepSeekBalance: true
        )
        XCTAssertTrue(displayable.isEmpty, "非 DeepSeek 的 provider 绝不展示 DeepSeek 余额卡")
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
        XCTAssertEqual(visibleProviders, [.antigravity, .deepSeek, .codex], "卡片顺序与偏好设置严格一致")
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

        // 仅一家供应商有数据时：只展示 1 个卡片，无分割线
        let singleActive = displayable(from: [.codex])
        XCTAssertEqual(singleActive, [.codex])
        let singleSeparators = singleActive.enumerated().compactMap { index, _ in index > 0 ? index : nil }
        XCTAssertTrue(singleSeparators.isEmpty, "单个供应商卡片不应有分割线")
    }

    // MARK: - 凭证类 provider 展示候选（2026-08-26）

    func test_displayPolicy_includesCredentialConfiguredArkAndOpencodeWithoutConfiguredLimitSnapshots() {
        let visible = TokenUsageProviderDisplayPolicy.providers(
            providerOrder: TokenUsageProvider.allCases,
            configuredLimitProviders: [.codex],
            credentialConfiguredProviders: [.opencode, .arkCodingPlan],
            showingDeepSeekBalance: false,
            hiddenProviders: []
        )

        XCTAssertEqual(visible, [.codex, .opencode, .arkCodingPlan], "有凭证但暂无有效限额窗口时仍应进入胶囊与弹层候选")
    }

    func test_displayPolicy_hiddenProviderExcludedFromPanelButCanRemainInPopoverCandidate() {
        let panelVisible = TokenUsageProviderDisplayPolicy.providers(
            providerOrder: TokenUsageProvider.allCases,
            configuredLimitProviders: [],
            credentialConfiguredProviders: [.opencode, .arkCodingPlan],
            showingDeepSeekBalance: false,
            hiddenProviders: [.opencode]
        )
        let popoverVisible = TokenUsageProviderDisplayPolicy.providers(
            providerOrder: TokenUsageProvider.allCases,
            configuredLimitProviders: [],
            credentialConfiguredProviders: [.opencode, .arkCodingPlan],
            showingDeepSeekBalance: false,
            hiddenProviders: []
        )

        XCTAssertEqual(panelVisible, [.arkCodingPlan], "主面板尊重隐藏开关")
        XCTAssertEqual(popoverVisible, [.opencode, .arkCodingPlan], "弹层保留隐藏 provider 以便重新打开")
    }

    func test_displayableCardProviders_includesCredentialConfiguredProviderBeforeLimitSnapshotArrives() {
        let displayable = TokenUsageProviderDisplayPolicy.displayableCardProviders(
            from: [.opencode, .arkCodingPlan],
            limits: [:],
            credentialConfiguredProviders: [.opencode],
            showingDeepSeekBalance: false
        )

        XCTAssertEqual(displayable, [.opencode], "保存凭证后限额快照尚未返回时仍保留状态卡位置")
    }

    func test_credentialStateReader_detectsKeychainAndEnvironmentCredentials() {
        let opencodeStore = PanelFilteringOpencodeStore(key: "  opencode-key  ")
        let arkStore = PanelFilteringArkStore(credentials: nil)
        let providers = TokenUsageCredentialStateReader.configuredProviders(
            opencodeStore: opencodeStore,
            arkStore: arkStore,
            environment: [
                "ARK_AK": "ark-ak",
                "ARK_SK": "ark-sk",
            ]
        )

        XCTAssertEqual(providers, [.opencode, .arkCodingPlan])
    }
}

private final class PanelFilteringOpencodeStore: OpencodeAPIKeyStoring {
    var key: String?

    init(key: String?) {
        self.key = key
    }

    func readAPIKey() throws -> String? { key }
    func writeAPIKey(_ apiKey: String) throws { key = apiKey }
    func deleteAPIKey() throws { key = nil }
}

private final class PanelFilteringArkStore: ArkCredentialsStoring {
    var credentials: ArkCredentials?

    init(credentials: ArkCredentials?) {
        self.credentials = credentials
    }

    func readCredentials() throws -> ArkCredentials? { credentials }
    func writeCredentials(_ credentials: ArkCredentials) throws { self.credentials = credentials }
    func deleteCredentials() throws { credentials = nil }
}

