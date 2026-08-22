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
            providerChip(title: strings.tokenProviderAll, selected: true) {}
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.06))
        )
    }

    private func providerChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Stats.font12Medium)
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
        // 骨架阶段无数据：恒空态；限额/用量区块在该票之后按快照开关。
        TokenUsageEmptyStateView(strings: strings)
            .frame(maxWidth: .infinity, minHeight: ControlCenterContentMetrics.emptyContentMinHeight)
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
