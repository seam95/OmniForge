import SwiftUI

/// 控制中心「Token」页 — 双分区（子 tab）布局：「余额」= 供应商限额/余额卡，
/// 「用量」= 本地统计仪表盘（汇总卡 + 热力图 + 趋势图 + 模型 Top）。
///
/// 余额区固定展示全部已配置供应商（无 provider 筛选）；「限额显示」齿轮位于
/// 分段行右端；任一分区无数据时整块隐藏，面板级无任何配置时走
/// `TokenUsageEmptyStateView` 空态（SPEC 4.2 / 4.3 / 4.6）。
struct TokenUsagePanelView: View {
    @ObservedObject var manager: TokenUsageManager
    @ObservedObject var preferences: TokenUsagePreferences
    /// DeepSeek 余额（可选：管理器尚未接线/未注册时为 nil）。
    /// 注意：不用 `@ObservedObject`（不接受 Optional 包装）——余额变化由 AppState
    /// `forwardObjectWillChange` 转发触发外层刷新，面板随之重算。
    var balanceManager: DeepSeekBalanceManager? = nil
    let strings: Strings
    var onOpenSettings: (SettingsToolbarTab?) -> Void = { _ in }

    /// 当前子 tab 分区（余额 / 用量），默认余额。
    @State private var selectedSection: TokenPanelSection = .balance
    /// 齿轮弹层（限额显示）展示状态。
    @State private var showsLimitsSettings = false
    /// 凭证已配置但暂无有效限额窗口的 provider（OpenCode / 方舟 Coding Plan）。
    @State private var credentialConfiguredProviders: Set<TokenUsageProvider> = []
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .onAppear { reloadCredentialConfiguredProviders() }
        .onChange(of: manager.limits) { _, _ in
            reloadCredentialConfiguredProviders()
        }
    }

    private var summaryCardsBlock: some View {
        TokenUsageSummaryCardsView(
            cards: manager.summaryCards(filteredBy: nil),
            strings: strings
        )
    }

    // MARK: - 限额显示齿轮

    /// 齿轮按钮（「限额显示」弹层）：剩余/消耗切换、provider 显隐与排序、重置提示/撒花开关。
    private var limitsSettingsButton: some View {
        Button {
            showsLimitsSettings.toggle()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text2 : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Theme.Stats.cardInset)
                )
        }
        .buttonStyle(.plain)
        .help(strings.tokenSettingsLimitsDisplay)
        .accessibilityLabel(strings.tokenSettingsLimitsDisplay)
        .accessibilityIdentifier(SettingsAccessibilityID.tokenUsageGearButton.rawValue)
        .popover(isPresented: $showsLimitsSettings, arrowEdge: .bottom) {
            TokenUsageLimitsSettingsPopover(
                preferences: preferences,
                manager: manager,
                balanceManager: balanceManager,
                credentialConfiguredProviders: credentialConfiguredProviders,
                strings: strings,
                onOpenSettings: {
                    showsLimitsSettings = false
                    onOpenSettings(.tokenUsage)
                }
            )
        }
    }

    /// 所有已配置的 provider（含常规 limits provider 与 DeepSeek 余额 provider，按用户设置排序），
    /// 过滤掉用户在「限额显示」弹层中隐藏的 provider。
    private var visibleProviders: [TokenUsageProvider] {
        TokenUsageProviderDisplayPolicy.providers(
            providerOrder: preferences.configuration.providerOrder,
            configuredLimitProviders: Set(manager.configuredProviders),
            credentialConfiguredProviders: credentialConfiguredProviders,
            showingDeepSeekBalance: balanceManager?.showingBalanceCard ?? false,
            hiddenProviders: preferences.configuration.hiddenProviders
        )
    }

    /// 「余额 / 用量」子 tab 分段行：等分分段 + 右端「限额显示」齿轮。
    private var sectionSwitcherRow: some View {
        HStack(spacing: 8) {
            sectionSwitcher
            limitsSettingsButton
        }
    }

    /// 「余额 / 用量」子 tab 分段（底块滑移与内容淡切同享一套曲线）。
    private var sectionSwitcher: some View {
        PanelSegmentedControl(
            options: TokenPanelSection.allCases.map { option in
                .init(tag: option, title: option.title(strings))
            },
            selection: $selectedSection
        )
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        let showingBalance = balanceManager?.showingBalanceCard ?? false
        let hasAnyConfigured = manager.hasAnyConfiguredProvider || showingBalance
        if manager.limits.isEmpty && !showingBalance {
            // 首次抓取完成前（或从未拉取）→ 骨架加载态
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: ControlCenterContentMetrics.emptyContentMinHeight)
        } else if !hasAnyConfigured {
            TokenUsageEmptyStateView(strings: strings)
                .frame(maxWidth: .infinity, minHeight: ControlCenterContentMetrics.emptyContentMinHeight)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                sectionSwitcherRow
                // 内容随分区整组重算：id 变化触发 peer 淡切，
                // ZStack 顶对齐让新旧内容在转场期间叠放不跳动。
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 10) {
                        switch selectedSection {
                        case .balance: balanceSection
                        case .usage: usageSection
                        }
                    }
                    .id(selectedSection)
                    .peerTransition()
                }
                .animation(Theme.Animation.pageTransition, value: selectedSection)
            }
        }
    }

    /// 余额分区：全部已配置 provider 的限额卡与余额卡 + 来源脚注；
    /// 无可展示卡片（如限额快照未返回）时给占位。
    @ViewBuilder
    private var balanceSection: some View {
        let displayableProviders = TokenUsageProviderDisplayPolicy.displayableCardProviders(
            from: visibleProviders,
            limits: manager.limits,
            credentialConfiguredProviders: credentialConfiguredProviders,
            showingDeepSeekBalance: balanceManager?.showingBalanceCard ?? false
        )
        if displayableProviders.isEmpty {
            sectionPlaceholder(strings.tokenBalanceEmptyHint)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(displayableProviders.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 {
                            providerSeparator
                        }
                        if let limits = limitSnapshot(for: provider) {
                            TokenUsageLimitCardView(
                                limits: limits,
                                strings: strings,
                                displayMode: preferences.configuration.limitsDisplayMode,
                                now: Date()
                            )
                        }
                        if provider == .deepSeek,
                           let balanceManager,
                           balanceManager.showingBalanceCard {
                            DeepSeekBalanceCardView(
                                snapshot: balanceManager.snapshot,
                                threshold: preferences.configuration.deepSeekBalanceSettings.lowBalanceThreshold,
                                strings: strings,
                                now: Date()
                            )
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white)
                )
                footerLine
            }
        }
    }

    /// 用量分区：汇总卡 + 仪表盘（热力图 / 趋势 / 模型 Top）+ 本地统计脚注。
    /// 有本地数据或回填中时显示（回填中以现有数据渲染，数值逐步回填），否则占位。
    @ViewBuilder
    private var usageSection: some View {
        if manager.usageBackfilling || manager.hasUsageData {
            VStack(alignment: .leading, spacing: 10) {
                summaryCardsBlock
                usageBlock
            }
        } else {
            sectionPlaceholder(strings.tokenEmptyHint)
        }
    }

    /// 分区级空态占位（居中轻文案，保持分段切换器在位）。
    private func sectionPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(Theme.Stats.font12Medium)
            .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    private func limitSnapshot(for provider: TokenUsageProvider) -> ProviderUsageLimits? {
        if let limits = manager.limits[provider] {
            return limits
        }
        guard TokenUsageProviderDisplayPolicy.credentialDrivenProviders.contains(provider),
              credentialConfiguredProviders.contains(provider) else {
            return nil
        }
        return .notConfigured(provider)
    }

    private func reloadCredentialConfiguredProviders() {
        credentialConfiguredProviders = TokenUsageCredentialStateReader.configuredProviders()
    }

    private var providerSeparator: some View {
        Rectangle()
            .fill(colorScheme == .light ? Theme.Stats.separator : Color.white.opacity(0.08))
            .frame(height: 0.5)
    }

    /// 用量仪表盘（2026-08-25 重设计）：活跃度 + 趋势 + 模型 + 本地统计脚注，
    /// 由「用量」分区承载（汇总卡在分区层先行）。
    @ViewBuilder
    private var usageBlock: some View {
        if manager.usageBackfilling || manager.hasUsageData {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 14) {
                    TokenUsageActivityHeatmapView(
                        heatmap: manager.activityHeatmap(filteredBy: nil),
                        strings: strings
                    )
                    TokenUsageTrendChartView(
                        points: manager.trendPoints(filteredBy: nil, period: trendPeriod),
                        period: trendPeriodBinding,
                        strings: strings
                    )
                    TokenUsageTopModelsView(
                        models: manager.topModels(filteredBy: nil, period: trendPeriod),
                        strings: strings
                    )
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white)
                )
                usageFooterLine
            }
        }
    }

    /// 趋势周期（读写 `configuration.trendPeriodDefault`，持久化）。
    private var trendPeriod: TokenTrendPeriod {
        preferences.configuration.trendPeriodDefault
    }

    private var trendPeriodBinding: Binding<TokenTrendPeriod> {
        Binding(
            get: { preferences.configuration.trendPeriodDefault },
            set: { newValue in preferences.update { $0.trendPeriodDefault = newValue } }
        )
    }

    /// 用量来源标注：「本地统计 · 每 5 分钟汇总」。
    private var usageFooterLine: some View {
        Text(String(format: strings.tokenUsageLocalFormat, Int(ClaudeUsageCollector.defaultScanInterval / 60)))
            .font(Theme.Stats.font10Regular)
            .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 来源脚注：「10 分钟前更新 · 官方来源 · 5 家已配置 4 家」（ⓘ 提示可打开的设置页，参考 UI 稿）。
    private var footerLine: some View {
        let allConfiguredProviders = TokenUsageProviderDisplayPolicy.providers(
            providerOrder: preferences.configuration.providerOrder,
            configuredLimitProviders: Set(manager.configuredProviders),
            credentialConfiguredProviders: credentialConfiguredProviders,
            showingDeepSeekBalance: balanceManager?.showingBalanceCard ?? false,
            hiddenProviders: []
        )
        let activeCount = allConfiguredProviders.filter { provider in
            guard let limits = manager.limits[provider] else { return false }
            return limits.issue == nil && !limits.windows.isEmpty
        }.count
        let updated = TokenUsageFormat.relativeUpdate(manager.limitUpdateAt, strings: strings)
        return HStack(spacing: 4) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text(
                String(
                    format: strings.tokenFooterFormat,
                    updated,
                    strings.tokenSourceOfficial,
                    allConfiguredProviders.count,
                    activeCount
                )
            )
        }
        .font(Theme.Stats.font10Regular)
        .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// 空态：未检测到任何 provider 登录。
struct TokenUsageEmptyStateView: View {
    let strings: Strings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
            Text(strings.tokenEmptyHint)
                .font(Theme.Stats.font12Medium)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
    }
}

/// Token 面板内部分区（子 tab）：余额（供应商限额/余额卡）与用量（本地统计仪表盘）。
/// CaseIterable 声明顺序即分段展示顺序（余额在前，用量在后）。
enum TokenPanelSection: CaseIterable {
    case balance
    case usage

    func title(_ strings: Strings) -> String {
        switch self {
        case .balance: return strings.tokenSectionBalance
        case .usage: return strings.tokenSectionUsage
        }
    }
}
