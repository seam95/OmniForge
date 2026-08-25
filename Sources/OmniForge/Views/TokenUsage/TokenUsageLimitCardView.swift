import SwiftUI

/// 单个 provider 的限额区块（去卡片化透明布局，单行四段式窗口行）。
/// 布局：标题行（16x16 图标 + 名称 + 右侧附加信息）+ 窗口行（标签 40pt / 5pt 进度条 / 百分比 34pt / 重置时间 30pt）。
struct TokenUsageLimitCardView: View {
    let limits: ProviderUsageLimits
    let strings: Strings
    /// 数值口径：已用 / 剩余（设置项）。
    let displayMode: TokenUsageLimitsDisplay
    /// 注入「现在」以便说明行文案可测。
    let now: Date

    private var status: TokenUsageCardStatus {
        TokenUsageCardStatus.derive(from: limits)
    }

    private var orderedWindows: [(kind: LimitWindowKind, window: UsageWindow)] {
        let preferredOrder: [LimitWindowKind]
        switch limits.provider {
        case .codex:
            preferredOrder = [.weekly, .session, .monthly, .credits]
        default:
            preferredOrder = [.weekly, .session, .monthly, .credits]
        }
        return preferredOrder.compactMap { kind in
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
            if let issue = limits.issue {
                if limits.stale, !orderedWindows.isEmpty {
                    windowsBody
                    if !labeledWindows.isEmpty {
                        labeledWindowsBody
                    }
                    resetBankRow
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
                resetBankRow
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            TokenUsageProviderIconView(provider: limits.provider, size: 16, cornerRadius: 4)
            Text(headerTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.Stats.text1)
            Spacer()
            if let planSubtitle {
                Text(planSubtitle)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(Theme.Stats.text3)
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

    /// 单行四段式窗口行：[标签 40pt] [进度条 弹性] [已用/剩余% 34pt] [重置时间 30pt]
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
                .foregroundColor(Theme.Stats.text2)
                .lineLimit(1)
                .frame(width: 40, alignment: .leading)

            LimitBar(
                value: progress,
                barColor: barColor
            )

            Text(valueText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.Stats.text1)
                .lineLimit(1)
                .frame(width: 34, alignment: .trailing)

            Text(resetTime ?? "")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(Theme.Stats.text3)
                .lineLimit(1)
                .frame(width: 30, alignment: .trailing)
        }
        .frame(height: 16)
    }

    // MARK: - 重置权益独立行

    @ViewBuilder
    private var resetBankRow: some View {
        if limits.provider == .codex,
           let resetBank = limits.resetBank,
           let earliest = resetBank.credits.first?.expiresAt {
            HStack(spacing: 8) {
                Text(strings.tokenResetBankTitle)
                    .font(Theme.Stats.font11Regular)
                    .foregroundColor(Theme.Stats.text2)
                    .frame(width: 60, alignment: .leading)
                Spacer()
                Text(TokenUsageFormat.differentDayTime(earliest))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(Theme.Stats.text3)
            }
            .frame(height: 16)
        }
    }

    // MARK: - 错误态

    private func errorRow(_ issue: LimitError) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundColor(status.tint)
            Text(TokenUsageFormat.errorCaption(for: issue, now: now, strings: strings))
                .font(Theme.Stats.font10Regular)
                .foregroundColor(Theme.Stats.text2)
        }
    }
}

/// 连续式极简进度条：高 5pt，圆角 2.5，底轨 #EDEDEF。
private struct LimitBar: View {
    let value: Double
    let barColor: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let clamped = min(max(value, 0), 1)
            let fillWidth = max(0, min(width, width * clamped))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(red: 0xED / 255.0, green: 0xED / 255.0, blue: 0xEF / 255.0))
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
