import SwiftUI

/// 单个 provider 的限额卡：头部（18x18 品牌图标 + 名称/订阅计划）+ 窗口行（短标签 /
/// 进度条 + 步速刻度 / 百分比）+ 重置权益独立行。错误态时卡片体降级为错误说明行。
struct TokenUsageLimitCardView: View {
    let limits: ProviderUsageLimits
    let strings: Strings
    /// 数值口径：已用 / 剩余（设置项）。
    let displayMode: TokenUsageLimitsDisplay
    /// 注入「现在」以便说明行文案可测。
    let now: Date

    @State private var labelColumnWidth: CGFloat = 24

    private var status: TokenUsageCardStatus {
        TokenUsageCardStatus.derive(from: limits)
    }

    private var orderedWindows: [(kind: LimitWindowKind, window: UsageWindow)] {
        let preferredOrder: [LimitWindowKind]
        switch limits.provider {
        case .kimi:
            preferredOrder = [.weekly, .session, .monthly, .credits]
        case .codex:
            preferredOrder = [.weekly, .session, .monthly, .credits]
        case .cursor:
            preferredOrder = [.monthly, .session, .weekly, .credits]
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
        VStack(alignment: .leading, spacing: 10) {
            header
            if let issue = limits.issue {
                if limits.stale, !orderedWindows.isEmpty {
                    // 断网/超时/冷却回退：显示上一次成功快照 + 行内错误提示（stale 标注见徽章与脚注）。
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
        .padding(12)
        .omniCardStyle()
        .onPreferenceChange(LimitLabelWidthKey.self) { labelColumnWidth = ceil($0) }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            TokenUsageProviderIconView(provider: limits.provider, size: 18, cornerRadius: 4)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(headerTitle)
                    .font(Theme.Stats.font13SemiBold)
                    .foregroundColor(Theme.Stats.text1)
                if let planSubtitle {
                    Text(planSubtitle)
                        .font(Theme.Stats.font11Regular)
                        .foregroundColor(Theme.Stats.text3)
                }
            }
            Spacer()
            if status != .normal {
                StatusTintBadge(text: status.label(strings), tint: status.tint)
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
        VStack(alignment: .leading, spacing: 7) {
            ForEach(orderedWindows.indices, id: \.self) { index in
                windowRow(orderedWindows[index].kind, window: orderedWindows[index].window)
            }
        }
    }

    private var labeledWindowsBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(labeledWindows.indices, id: \.self) { index in
                labeledWindowRow(labeledWindows[index])
            }
        }
    }

    private func windowRow(_ kind: LimitWindowKind, window: UsageWindow) -> some View {
        let pace = computePace(kind: kind, window: window)
        let label = kind.shortTitle(for: limits.provider, strings: strings)
        let valueText = TokenUsageFormat.limitValueText(kind: kind, window: window, displayMode: displayMode, strings: strings)
        let progress = displayMode == .used
            ? TokenUsageFormat.limitBarProgress(for: window)
            : max(0, 100 - window.usedPercent) / 100
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
            tint: barColor,
            pacePercent: pace.pacePercent,
            paceOver: pace.paceOver
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
        let progress = displayMode == .used
            ? TokenUsageFormat.limitBarProgress(for: entry.window)
            : max(0, 100 - entry.window.usedPercent) / 100
        let barColor = TokenUsageFormat.limitBarStatusColor(
            percent: percentValue,
            displayMode: displayMode,
            tint: limits.provider.accentColor
        )

        return limitRow(
            label: label,
            valueText: valueText,
            progress: progress,
            tint: barColor,
            pacePercent: nil,
            paceOver: false
        )
    }

    private func limitRow(
        label: String,
        valueText: String,
        progress: Double,
        tint: Color,
        pacePercent: Double?,
        paceOver: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Theme.Stats.font11Regular)
                .foregroundColor(Theme.Stats.text2)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: LimitLabelWidthKey.self, value: proxy.size.width)
                })
                .frame(width: max(24, labelColumnWidth), alignment: .leading)

            LimitBarWithPace(
                value: progress,
                barColor: tint,
                pacePercent: pacePercent,
                paceOver: paceOver
            )

            Text(valueText)
                .font(Theme.Stats.font12Medium)
                .foregroundColor(Theme.Stats.text1)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 32, alignment: .trailing)
        }
        .frame(height: 16)
    }

    // MARK: - 重置权益独立行

    @ViewBuilder
    private var resetBankRow: some View {
        if limits.provider == .codex,
           let resetBank = limits.resetBank,
           let earliest = resetBank.credits.first?.expiresAt {
            HStack {
                Text(strings.tokenResetBankTitle)
                    .font(Theme.Stats.font11Regular)
                    .foregroundColor(Theme.Stats.text2)
                Spacer()
                Text(TokenUsageFormat.differentDayTime(earliest))
                    .font(Theme.Stats.font11Regular)
                    .foregroundColor(Theme.Stats.text3)
                    .monospacedDigit()
            }
            .frame(height: 16)
        }
    }

    private func computePace(kind: LimitWindowKind, window: UsageWindow) -> LimitPace.Result {
        // SPEC：仅窗口秒数可信的会话/周窗画步速刻度；月度/计费周期不画。
        guard kind == .session || kind == .weekly else { return LimitPace.Result() }
        let secondsUntilReset = window.resetAt?.timeIntervalSince(now) ?? 0
        return LimitPace.compute(
            usedFraction: window.usedPercent / 100,
            windowSeconds: window.windowSeconds ?? 0,
            secondsUntilReset: secondsUntilReset,
            remainingMode: displayMode == .remaining
        )
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

/// 进度条 + 步速刻度：胶囊形态（高 6pt），刻度以细竖线跨在条上（超前红 / 正常绿）。
private struct LimitBarWithPace: View {
    let value: Double
    let barColor: Color
    let pacePercent: Double?
    let paceOver: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let clamped = MetricBar.clamp(value)
            let fillWidth = max(0, min(width, width * clamped))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 6)

                if fillWidth > 0 {
                    Capsule()
                        .fill(barColor)
                        .frame(width: fillWidth, height: 6)
                }

                if let pacePercent {
                    let clampedPace = min(max(pacePercent, 0), 100)
                    let xPos = width * clampedPace / 100
                    RoundedRectangle(cornerRadius: 1)
                        .fill(paceOver ? Theme.Stats.up : Theme.Stats.statusNormal)
                        .frame(width: 2, height: 8)
                        .offset(x: max(0, min(max(0, width - 2), xPos - 1)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 8)
        .animation(.easeOut(duration: 0.25), value: value)
    }
}

/// 统一单卡内所有行标签的列宽偏好键。
private struct LimitLabelWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 24
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
