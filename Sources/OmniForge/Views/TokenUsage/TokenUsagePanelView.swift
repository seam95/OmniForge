import SwiftUI

/// 控制中心「Token」页 — 双分区（子 tab）布局：「余额」= 供应商限额/余额分区，
/// 「用量」= 本地统计仪表盘（汇总指标 + 热力图 + 趋势图 + 模型 Top）。
///
/// 平面分区布局（对齐监控 overview）：无卡片，浅色白底由容器转场层承载，
/// 分区之间 1pt 发丝线分隔，脚注以 caption 形式挂在内容尾部。
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
    @Environment(\.controlCenterSizing) private var sizingContext

    var body: some View {
        content
            .padding(.top, 2)
            // 凭证状态由 manager 缓存（SPEC §9.2.4）：进入页面/切换分区只读缓存，
            // 不再在 SwiftUI 生命周期中访问 Keychain。
            .task { credentialConfiguredProviders = manager.credentialConfiguredProviders }
            .onChange(of: manager.credentialConfiguredProviders) { _, newValue in
                credentialConfiguredProviders = newValue
            }
    }

    private var summaryCardsBlock: some View {
        TokenUsageSummaryCardsView(
            cards: manager.dashboardSnapshot?.summaryCards ?? manager.summaryCards(filteredBy: nil),
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
            VStack(alignment: .leading, spacing: 0) {
                sectionSwitcherRow
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                // 余额/用量平级切换：按分段顺序方向化滑移（SPEC 三期）。
                // 分区行（分段 + 齿轮）位于 Host 外，不随内容重建。
                PageSwitchHost(
                    requestedRoute: selectedSection,
                    semantics: { from, to in
                        .lateral(from: from, to: to, order: TokenPanelSection.allCases)
                    },
                    surface: { _ in .clear },
                    onRouteMountedBarrier: sizingContext.map { context in
                        { section, proceed in
                            context.mountStarted(path: "token/\(section)", proceed: proceed)
                        }
                    }
                ) { section in
                    VStack(alignment: .leading, spacing: 0) {
                        switch section {
                        case .balance: balanceSection
                        case .usage: usageSection
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    /// 余额分区：全部已配置 provider 的限额/余额平面分区（发丝线分隔）+ 来源 caption；
    /// 无可展示分区（如限额快照未返回）时给占位。
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
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(displayableProviders.enumerated()), id: \.element.id) { index, provider in
                    if index > 0 {
                        hairline
                    }
                    providerBlock(provider)
                }
                sourceCaption
            }
        }
    }

    /// 单个 provider 余额分区：限额卡（或未配置占位）+ DeepSeek 余额块。
    private func providerBlock(_ provider: TokenUsageProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 分区分隔发丝线（与监控 overview 同款 1pt，浅色 #F0F0F0）。
    private var hairline: some View {
        Rectangle()
            .fill(MonitorOverviewPalette.hairline(colorScheme))
            .frame(height: 1)
    }

    /// 用量分区：汇总指标区 + 仪表盘（热力图 / 趋势 / 模型 Top）平面分区 + 本地统计 caption。
    /// 有本地数据或回填中时显示（回填中以现有数据渲染，数值逐步回填），否则占位。
    @ViewBuilder
    private var usageSection: some View {
        if manager.usageBackfilling || manager.hasUsageData {
            VStack(alignment: .leading, spacing: 0) {
                summaryCardsBlock

                hairline
                usageSectionView(
                    TokenUsageActivityHeatmapView(
                        heatmap: usageHeatmap,
                        strings: strings
                    )
                )

                hairline
                usageSectionView(
                    TokenUsageTrendChartView(
                        points: trendPoints,
                        period: trendPeriodBinding,
                        strings: strings
                    )
                )

                if !topModels.isEmpty {
                    hairline
                    usageSectionView(
                        TokenUsageTopModelsView(
                            models: topModels,
                            strings: strings
                        )
                    )
                }

                localStatsCaption
            }
        } else {
            sectionPlaceholder(strings.tokenEmptyHint)
        }
    }

    /// 仪表盘分区统一内边距（对齐监控网络/磁盘分区 h16 v12）。
    private func usageSectionView(_ view: some View) -> some View {
        view
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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

    /// 用量分区渲染数据（SPEC §9.2.1/§9.2.2）：趋势点与模型 Top 经
    /// `TokenPanelUsageRenderData` 只读 dashboard 快照，渲染路径零存储访问；
    /// 热力图/汇总卡可安全回退到内存聚合（只读 `usageDailyProviderAggregates`
    /// 缓存，不触存储）。
    private var renderData: TokenPanelUsageRenderData {
        TokenPanelUsageRenderData(dashboard: manager.dashboardSnapshot, period: trendPeriod)
    }

    private var usageHeatmap: UsageActivityHeatmap? {
        if let heatmap = manager.dashboardSnapshot?.heatmap { return heatmap }
        return manager.activityHeatmap(filteredBy: nil)
    }

    private var trendPoints: [UsageTrendPoint] {
        renderData.trendPoints
    }

    private var topModels: [UsageTopModelEntry] {
        renderData.topModels
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

    /// 用量来源 caption：「本地统计 · 每 5 分钟汇总」（挂仪表盘尾部，左对齐）。
    private var localStatsCaption: some View {
        Text(String(format: strings.tokenUsageLocalFormat, Int(ClaudeUsageCollector.defaultScanInterval / 60)))
            .font(Theme.Stats.font10Regular)
            .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 来源 caption：「10 分钟前更新 · 官方来源 · 5 家已配置 4 家」
    /// （ⓘ 提示可打开的设置页，挂余额分区尾部，左对齐）。
    private var sourceCaption: some View {
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
        .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
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
