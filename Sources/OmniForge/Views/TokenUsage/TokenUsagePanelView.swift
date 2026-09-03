import SwiftUI

/// 控制中心「Token」页 — 单页布局：限额区块（上）+ 用量仪表盘区块（下）。
///
/// 顶部 provider 切换器始终保留；两区块任一无数据时整块隐藏，
/// 均为空时走 `TokenUsageEmptyStateView` 空态（SPEC 4.2 / 4.3 / 4.6）。
///
/// 用量区块为仪表盘（SPEC 2026-08-25）：
/// 汇总卡 ×4 + 活跃度热力图 + 趋势图（日/周/月/总计，自带切换器）+ 模型 Top 列表；
/// provider 切换器过滤全部四个子区块。
struct TokenUsagePanelView: View {
    /// Provider 胶囊选中底块 matchedGeometry 标识：底块在胶囊间平滑滑移。
    private static let providerChipIndicatorID = "token-provider-chip-active"

    @ObservedObject var manager: TokenUsageManager
    @ObservedObject var preferences: TokenUsagePreferences
    /// DeepSeek 余额（可选：管理器尚未接线/未注册时为 nil）。
    /// 注意：不用 `@ObservedObject`（不接受 Optional 包装）——余额变化由 AppState
    /// `forwardObjectWillChange` 转发触发外层刷新，面板随之重算。
    var balanceManager: DeepSeekBalanceManager? = nil
    let strings: Strings
    var onOpenSettings: (SettingsToolbarTab?) -> Void = { _ in }

    /// nil = 全部（配置的全部 provider 卡片堆叠）。
    @State private var selectedProvider: TokenUsageProvider?
    /// 齿轮弹层（限额显示）展示状态。
    @State private var showsLimitsSettings = false
    /// 凭证已配置但暂无有效限额窗口的 provider（OpenCode / 方舟 Coding Plan）。
    @State private var credentialConfiguredProviders: Set<TokenUsageProvider> = []
    @Namespace private var providerChipIndicator
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if manager.usageBackfilling || manager.hasUsageData {
                summaryCardsBlock
            }
            headerRow
            content
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .onAppear { reloadCredentialConfiguredProviders() }
        .onChange(of: manager.limits) { _, _ in
            reloadCredentialConfiguredProviders()
        }
        .onChange(of: preferences.configuration.hiddenProviders) { _, hidden in
            // 弹层隐藏了当前选中的 provider → 清除选中，回到「全部」视图
            if let selected = selectedProvider, hidden.contains(selected) {
                selectedProvider = nil
            }
        }
    }

    private var summaryCardsBlock: some View {
        TokenUsageSummaryCardsView(
            cards: manager.summaryCards(filteredBy: nil),
            strings: strings
        )
    }

    // MARK: - 头部行

    private var headerRow: some View {
        HStack(spacing: 8) {
            providerSwitcher
            limitsSettingsButton
        }
    }

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

    /// Provider 分段胶囊（仅已配置 provider + 「全部」）。
    private var providerSwitcher: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    providerChip(
                        title: strings.tokenProviderAll,
                        provider: nil,
                        selected: selectedProvider == nil
                    ) {
                        selectedProvider = nil
                    }
                    .id("all")
                    ForEach(visibleProviders) { provider in
                        providerChip(title: provider.displayName, provider: provider, selected: selectedProvider == provider) {
                            selectedProvider = provider
                        }
                        .id(provider.id)
                    }
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.06))
                )
                // 动画统一由 value 驱动：底块滑移与内容淡切同享一套曲线。
                .animation(Theme.Animation.pageTransition, value: selectedProvider)
            }
            .onChange(of: selectedProvider) { _, newProvider in
                if let newProvider {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(newProvider.id, anchor: .center)
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo("all", anchor: .leading)
                    }
                }
            }
        }
    }

    private func providerChip(
        title: String,
        provider: TokenUsageProvider?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let provider {
                    Circle()
                        .fill(provider.accentColor)
                        .frame(width: 5, height: 5)
                }
                Text(title)
                    .font(Theme.Stats.font12Medium)
                    .lineLimit(1)
            }
            .foregroundStyle(
                selected
                    ? (colorScheme == .light ? Theme.Stats.text1 : Color.white)
                    : (colorScheme == .light ? Theme.Stats.text2 : Color.secondary)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Theme.Stats.cardBackground)
                        .shadow(color: Color.black.opacity(colorScheme == .light ? 0.06 : 0.0), radius: 2, x: 0, y: 1)
                        .matchedGeometryEffect(id: Self.providerChipIndicatorID, in: providerChipIndicator)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
            // 内容随选中 provider 整组重算：id 变化触发 peer 淡切，
            // ZStack 顶对齐让新旧内容在转场期间叠放不跳动。
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    providerCardsBlock
                    usageBlock
                }
                .id(selectedProvider)
                .peerTransition()
            }
            .animation(Theme.Animation.pageTransition, value: selectedProvider)
        }
    }

    /// 供应商卡片区块：按偏好顺序展示选中 provider（或全部已配置 provider）的限额卡与余额卡 + 来源脚注行。
    @ViewBuilder
    private var providerCardsBlock: some View {
        let providers = selectedProvider.map { [$0] } ?? visibleProviders
        let displayableProviders = TokenUsageProviderDisplayPolicy.displayableCardProviders(
            from: providers,
            limits: manager.limits,
            credentialConfiguredProviders: credentialConfiguredProviders,
            showingDeepSeekBalance: balanceManager?.showingBalanceCard ?? false
        )
        if !displayableProviders.isEmpty {
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

    /// 用量仪表盘区块（2026-08-25 重设计）：汇总卡 + 活跃度 + 趋势 + 模型 + 本地统计脚注。
    /// 有本地数据或回填中时显示；回填中各区块以现有数据渲染（数值逐步回填）。
    @ViewBuilder
    private var usageBlock: some View {
        if manager.usageBackfilling || manager.hasUsageData {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 14) {
                    TokenUsageActivityHeatmapView(
                        heatmap: manager.activityHeatmap(filteredBy: selectedProvider),
                        strings: strings
                    )
                    TokenUsageTrendChartView(
                        points: manager.trendPoints(filteredBy: selectedProvider, period: trendPeriod),
                        period: trendPeriodBinding,
                        strings: strings
                    )
                    TokenUsageTopModelsView(
                        models: manager.topModels(filteredBy: selectedProvider, period: trendPeriod),
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
