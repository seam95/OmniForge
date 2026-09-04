import SwiftUI

/// 单个 provider 的限额区块（去卡片化透明布局，单行四段式窗口行）。
/// 布局：标题行（16x16 图标 + 名称 + 右侧附加信息）+ 窗口行（标签 40pt / 5pt 进度条 / 百分比 34pt / 重置时间 36pt）。
struct TokenUsageLimitCardView: View {
    let limits: ProviderUsageLimits
    let strings: Strings
    /// 数值口径：已用 / 剩余（设置项）。
    let displayMode: TokenUsageLimitsDisplay
    /// 注入「现在」以便说明行文案可测。
    let now: Date

    @Environment(\.colorScheme) private var colorScheme

    private var status: TokenUsageCardStatus {
        TokenUsageCardStatus.derive(from: limits)
    }

    /// 窗口排列顺序：5h 会话窗在上，7d 周窗在下，其后月窗与额度窗。
    static let windowKindOrder: [LimitWindowKind] = [.session, .weekly, .monthly, .credits]

    /// 窗口行右侧重置时间列宽：须容纳最宽形态 "HH:mm"（10pt SF Mono 5 字符恰 30pt 压线，
    /// 留余量防 lineLimit(1) 截断成 "13:…"）。改动列宽或字号须同步回归测试。
    static let resetTimeColumnWidth: CGFloat = 36

    private var orderedWindows: [(kind: LimitWindowKind, window: UsageWindow)] {
        Self.windowKindOrder.compactMap { kind in
            limits.windows[kind].map { (kind, $0) }
        }
    }

    /// 附加带标签窗口（Claude Opus/scoped、Cursor 车道、Codex Spark、Antigravity Gemini 双窗）。
    private var labeledWindows: [LabeledUsageWindow] {
        limits.labeledWindows ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !limits.configured {
                errorRow(unavailableCaption)
            } else if let issue = limits.issue {
                if limits.stale, !orderedWindows.isEmpty {
                    windowsBody
                    if !labeledWindows.isEmpty {
                        labeledWindowsBody
                    }
                    resetBankSection
                    errorRow(issue)
                } else {
                    errorRow(issue)
                }
            } else if orderedWindows.isEmpty && labeledWindows.isEmpty {
                errorRow(.decoding("empty windows"))
            } else {
                windowsBody
                if !labeledWindows.isEmpty {
                    labeledWindowsBody
                }
                resetBankSection
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            TokenUsageProviderIconView(provider: limits.provider, size: 16, cornerRadius: 4)
            Text(headerTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
            Spacer()
            if let planSubtitle {
                Text(planSubtitle)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
            }
        }
    }

    private var headerTitle: String {
        if let plan = limits.planLabel, !plan.isEmpty {
            return "\(limits.provider.displayName) \(plan)"
        }
        return limits.provider.displayName
    }

    private var planSubtitle: String? {
        nil
    }

    private var unavailableCaption: String {
        switch limits.provider {
        case .arkCodingPlan:
            return strings.tokenSettingsNoSubscription
        case .opencode:
            return strings.tokenSettingsNoQuotaAvailable
        default:
            return strings.tokenSettingsNotConfigured
        }
    }

    // MARK: - 窗口行

    private var windowsBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(orderedWindows.indices, id: \.self) { index in
                windowRow(orderedWindows[index].kind, window: orderedWindows[index].window)
            }
        }
    }

    private var labeledWindowsBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(labeledWindows.indices, id: \.self) { index in
                labeledWindowRow(labeledWindows[index])
            }
        }
    }

    private func windowRow(_ kind: LimitWindowKind, window: UsageWindow) -> some View {
        let label = kind.shortTitle(for: limits.provider, strings: strings)
        let valueText = TokenUsageFormat.limitValueText(kind: kind, window: window, displayMode: displayMode, strings: strings)
        let resetTime = TokenUsageFormat.windowResetTimeTiered(resetAt: window.resetAt, now: now)
        // 进度条宽度统一表达剩余百分比（100% 为满条）
        let progress = max(0, 100 - window.usedPercent) / 100
        let percentValue = displayMode == .used ? window.usedPercent : max(0, 100 - window.usedPercent)
        let barColor = TokenUsageFormat.limitBarStatusColor(
            percent: percentValue,
            displayMode: displayMode,
            tint: kind == .credits ? Theme.Stats.statusNormal : limits.provider.accentColor
        )

        return limitRow(
            label: label,
            valueText: valueText,
            progress: progress,
            barColor: barColor,
            resetTime: resetTime
        )
    }

    private func labeledWindowRow(_ entry: LabeledUsageWindow) -> some View {
        let label = TokenUsageFormat.labeledWindowShortTitle(
            label: entry.label,
            provider: limits.provider,
            strings: strings
        )
        let percentValue = displayMode == .used ? entry.window.usedPercent : max(0, 100 - entry.window.usedPercent)
        let valueText = TokenUsageFormat.percent(percentValue)
        let resetTime = TokenUsageFormat.windowResetTimeTiered(resetAt: entry.window.resetAt, now: now)
        let progress = max(0, 100 - entry.window.usedPercent) / 100
        let barColor = TokenUsageFormat.limitBarStatusColor(
            percent: percentValue,
            displayMode: displayMode,
            tint: limits.provider.accentColor
        )

        return limitRow(
            label: label,
            valueText: valueText,
            progress: progress,
            barColor: barColor,
            resetTime: resetTime
        )
    }

    /// 单行四段式窗口行：[标签 40pt] [进度条 弹性] [已用/剩余% 34pt] [重置时间 36pt]
    /// 重置时间列须容纳最宽形态 "HH:mm"（10pt SF Mono 5 字符 = 30pt 压线，留 6pt 余量防截断）。
    private func limitRow(
        label: String,
        valueText: String,
        progress: Double,
        barColor: Color,
        resetTime: String?
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Theme.Stats.font11Regular)
                .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                .lineLimit(1)
                .frame(width: 40, alignment: .leading)

            LimitBar(
                value: progress,
                barColor: barColor
            )

            Text(valueText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                .lineLimit(1)
                .frame(width: 34, alignment: .trailing)

            Text(resetTime ?? "")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                .lineLimit(1)
                .frame(width: Self.resetTimeColumnWidth, alignment: .trailing)
        }
        .frame(height: 16)
    }

    // MARK: - 重置权益区块

    /// 重置权益区块：每条权益一行（标签 / 剩余寿命条 / 过期时间），
    /// 列宽与窗口行对齐（标签 40pt，过期时间占满百分比+重置时间两列的 72pt）。
    @ViewBuilder
    private var resetBankSection: some View {
        if limits.provider == .codex, let resetBank = limits.resetBank {
            let rows = TokenUsageFormat.resetBankRowSpecs(resetBank: resetBank, now: now, strings: strings)
            if !rows.isEmpty || resetBank.displayCount != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if rows.isEmpty, let count = resetBank.displayCount {
                        // 官方只给了数量没有明细时的退化展示
                        Text(String(format: strings.tokenResetBankCountOnlyFormat, count))
                            .font(Theme.Stats.font10Regular)
                            .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(rows.indices, id: \.self) { index in
                                resetBankRow(rows[index])
                            }
                        }
                    }
                }
                .padding(.top, 1)
            }
        }
    }

    /// 单条重置权益行：寿命条固定绿色（表达剩余寿命而非消耗进度）。
    private func resetBankRow(_ row: ResetBankRowSpec) -> some View {
        HStack(spacing: 8) {
            Text(row.label)
                .font(Theme.Stats.font11Regular)
                .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                .lineLimit(1)
                .frame(width: 40, alignment: .leading)

            LimitBar(
                value: row.lifetimeRemaining,
                barColor: Theme.Stats.statusNormal
            )

            Text(row.expiryText)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                .lineLimit(1)
                .frame(width: 72, alignment: .trailing)
        }
        .frame(height: 16)
        .help(row.helpText)
    }

    // MARK: - 错误态

    private func errorRow(_ issue: LimitError) -> some View {
        // stale 快照保留 last-good 的 capturedAt，作为缓存时间写进文案。
        let cachedAt = limits.stale ? limits.capturedAt : nil
        let caption = TokenUsageFormat.errorCaption(
            for: issue,
            now: now,
            strings: strings,
            provider: limits.provider,
            cachedAt: cachedAt
        )
        // 未运行是本地进程型 provider 的常态兜底而非故障，用信息样式而非警告三角。
        if issue == .notRunning {
            return errorRow(caption, tint: Theme.Stats.text3, icon: "info.circle")
        }
        return errorRow(caption, tint: status.tint)
    }

    private func errorRow(
        _ caption: String,
        tint: Color = Theme.Stats.text3,
        icon: String = "exclamationmark.triangle.fill"
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(tint)
            Text(caption)
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
        }
    }
}

/// 连续式极简进度条：高 5pt，圆角 2.5；底轨对齐监控进度条语义色。
private struct LimitBar: View {
    let value: Double
    let barColor: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let clamped = min(max(value, 0), 1)
            let fillWidth = max(0, min(width, width * clamped))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.12))
                    .frame(height: 5)

                if fillWidth > 0 {
                    Capsule()
                        .fill(barColor)
                        .frame(width: fillWidth, height: 5)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.25), value: value)
    }
}
