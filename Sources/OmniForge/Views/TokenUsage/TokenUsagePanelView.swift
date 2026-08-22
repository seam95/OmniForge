import SwiftUI

/// 控制中心「Token」页 — 单页布局：限额区块（上）+ 用量区块（下）。
///
/// 顶部 provider 切换器与周期选择始终保留；两区块任一无数据时整块隐藏，
/// 均为空时走 `TokenUsageEmptyStateView` 空态（SPEC 4.2 / 4.3 / 4.6）。
struct TokenUsagePanelView: View {
    @ObservedObject var manager: TokenUsageManager
    @ObservedObject var preferences: TokenUsagePreferences
    let strings: Strings
    var onOpenSettings: (SettingsToolbarTab?) -> Void = { _ in }

    @AppStorage(UserDefaultsKeys.tokenUsageSelectedPeriod)
    private var selectedPeriodRawValue = TokenUsagePeriod.today.rawValue
    /// nil = 全部（配置的全部 provider 卡片堆叠）。
    @State private var selectedProvider: TokenUsageProvider?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            content
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    // MARK: - 头部行

    private var headerRow: some View {
        HStack(spacing: 8) {
            providerSwitcher
            Spacer(minLength: 4)
            periodMenu
        }
    }

    /// Provider 分段胶囊（仅已配置 provider + 「全部」）。
    private var providerSwitcher: some View {
        HStack(spacing: 3) {
            providerChip(
                title: strings.tokenProviderAll,
                provider: nil,
                selected: selectedProvider == nil
            ) {
                selectedProvider = nil
            }
            ForEach(manager.configuredProviders) { provider in
                providerChip(title: provider.displayName, provider: provider, selected: selectedProvider == provider) {
                    selectedProvider = provider
                }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.06))
        )
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
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 「今日 ▾」周期选择 — 仅作用于用量区块。
    private var periodMenu: some View {
        Menu {
            ForEach(TokenUsagePeriod.allCases) { period in
                Button {
                    selectedPeriodRawValue = period.rawValue
                } label: {
                    if period == selectedPeriod {
                        Label(period.title(in: strings), systemImage: "checkmark")
                    } else {
                        Text(period.title(in: strings))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedPeriod.title(in: strings))
                    .font(Theme.Stats.font12Medium)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var selectedPeriod: TokenUsagePeriod {
        TokenUsagePeriod(rawValue: selectedPeriodRawValue) ?? .today
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        if manager.limits.isEmpty {
            // 首次抓取完成前（或从未拉取）→ 骨架加载态
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: ControlCenterContentMetrics.emptyContentMinHeight)
        } else if !manager.hasAnyConfiguredProvider {
            TokenUsageEmptyStateView(strings: strings)
                .frame(maxWidth: .infinity, minHeight: ControlCenterContentMetrics.emptyContentMinHeight)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                limitsBlock
                usageBlock
            }
        }
    }

    /// 限额区块：选中 provider 的卡片（「全部」= 所有已配置卡片堆叠）+ 来源脚注行。
    private var limitsBlock: some View {
        let providers = selectedProvider
            .map { [$0] }
            ?? manager.configuredProviders
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(providers) { provider in
                if let limits = manager.limits[provider] {
                    TokenUsageLimitCardView(
                        limits: limits,
                        strings: strings,
                        displayMode: preferences.configuration.limitsDisplayMode,
                        now: Date()
                    )
                }
            }
            footerLine
        }
    }

    /// 用量区块（#04/#05）：今日用量卡 + 分布卡 + 本地统计标注行。
    /// 无数据且未回填时整块隐藏（SPEC 4.3）；回填中仍显示（数值位为「正在统计历史用量…」）。
    @ViewBuilder
    private var usageBlock: some View {
        if manager.usageBackfilling || selectedUsageOverview != nil {
            let distribution = selectedDistribution
            VStack(alignment: .leading, spacing: 10) {
                TokenUsageTodayCardView(
                    overview: selectedUsageOverview,
                    backfilling: manager.usageBackfilling,
                    providerCount: distribution?.byProvider.count ?? fallbackProviderCount,
                    period: selectedPeriod,
                    strings: strings
                )
                if let distribution {
                    TokenUsageDistributionCardView(
                        distribution: distribution,
                        strings: strings
                    )
                }
                usageFooterLine
            }
        }
    }

    /// 周期内无当日数据但周期有数据时的 provider 家数兜底（今日快照口径）。
    private var fallbackProviderCount: Int {
        selectedProvider == nil
            ? manager.usageProvidersWithData.count
            : 1
    }

    /// 选中 provider + 选中周期的用量快照。
    private var selectedUsageOverview: TokenUsageOverview? {
        manager.usageOverview(filteredBy: selectedProvider, period: selectedPeriod)
    }

    /// 选中 provider + 选中周期的分布（按模型 / 按 Provider）。
    private var selectedDistribution: UsageDistribution? {
        manager.usageDistribution(filteredBy: selectedProvider, period: selectedPeriod)
    }

    /// 用量来源标注：「本地统计 · 每 5 分钟汇总」。
    private var usageFooterLine: some View {
        Text(String(format: strings.tokenUsageLocalFormat, Int(ClaudeUsageCollector.defaultScanInterval / 60)))
            .font(Theme.Stats.font10Regular)
            .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 来源脚注：「10 分钟前更新 · 官方来源 · 5 家已配置 4 家」。
    private var footerLine: some View {
        let activeCount = manager.configuredProviders.filter { provider in
            guard let limits = manager.limits[provider] else { return false }
            return limits.issue == nil && !limits.windows.isEmpty
        }.count
        let updated = TokenUsageFormat.relativeUpdate(manager.limitUpdateAt, strings: strings)
        return Text(
            String(
                format: strings.tokenFooterFormat,
                updated,
                strings.tokenSourceOfficial,
                manager.configuredProviders.count,
                activeCount
            )
        )
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
