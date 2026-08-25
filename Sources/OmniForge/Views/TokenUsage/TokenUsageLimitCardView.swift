import SwiftUI

/// 单个 provider 的限额卡：头部（色块 + 名称 + 订阅计划 + 状态徽章）+ 窗口行（短标签 /
/// 进度条 + 步速刻度 / 百分比 / 重置时间）。错误态时卡片体降级为错误说明行。
struct TokenUsageLimitCardView: View {
    let limits: ProviderUsageLimits
    let strings: Strings
    /// 数值口径：已用 / 剩余（设置项）。
    let displayMode: TokenUsageLimitsDisplay
    /// 注入「现在」以便说明行文案可测。
    let now: Date

    @State private var labelColumnWidth: CGFloat = 20

    private var status: TokenUsageCardStatus {
        TokenUsageCardStatus.derive(from: limits)
    }

    private var orderedWindows: [(kind: LimitWindowKind, window: UsageWindow)] {
        [.session, .weekly, .monthly, .credits].compactMap { kind in
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
            }
        }
        .padding(12)
        .omniCardStyle()
        .onPreferenceChange(LimitLabelWidthKey.self) { labelColumnWidth = ceil($0) }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(limits.provider.accentColor)
                .frame(width: 6, height: 6)
            Text(limits.provider.displayName)
                .font(Theme.Stats.font13SemiBold)
                .foregroundColor(Theme.Stats.text1)
            if let planLabel = limits.planLabel {
                Text(planLabel)
                    .font(Theme.Stats.font11Regular)
                    .foregroundColor(Theme.Stats.text3)
            }
            Spacer()
            StatusTintBadge(text: status.label(strings), tint: status.tint)
        }
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
        let resetTime = TokenUsageFormat.windowResetTime(resetAt: window.resetAt, now: now)
        let label = kind.shortTitle(strings)
        let valueText = TokenUsageFormat.limitValueText(kind: kind, window: window, displayMode: displayMode, strings: strings)
        let tint = kind == .credits ? Theme.Stats.statusNormal : limits.provider.accentColor
        let warning: Double = kind == .credits ? 101 : 70
        let critical: Double = kind == .credits ? 102 : 90

        return limitRow(
            label: label,
            valueText: valueText,
            progress: TokenUsageFormat.limitBarProgress(for: window),
            tint: tint,
            warning: warning,
            critical: critical,
            pacePercent: pace.pacePercent,
            paceOver: pace.paceOver,
            resetTime: resetTime
        )
    }

    private func labeledWindowRow(_ entry: LabeledUsageWindow) -> some View {
        let resetTime = TokenUsageFormat.windowResetTime(resetAt: entry.window.resetAt, now: now)
        let valueText = TokenUsageFormat.percent(entry.window.usedPercent)

        return limitRow(
            label: entry.label,
            valueText: valueText,
            progress: TokenUsageFormat.limitBarProgress(for: entry.window),
            tint: limits.provider.accentColor,
            warning: 70,
            critical: 90,
            pacePercent: nil,
            paceOver: false,
            resetTime: resetTime
        )
    }

    private func limitRow(
        label: String,
        valueText: String,
        progress: Double,
        tint: Color,
        warning: Double,
        critical: Double,
        pacePercent: Double?,
        paceOver: Bool,
        resetTime: String?
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
                .frame(width: max(20, labelColumnWidth), alignment: .leading)

            LimitBarWithPace(
                value: progress,
                tint: tint,
                warning: warning,
                critical: critical,
                pacePercent: pacePercent,
                paceOver: paceOver
            )

            Text(valueText)
                .font(Theme.Stats.font12Medium)
                .foregroundColor(Theme.Stats.text1)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 36, alignment: .trailing)

            if let resetTime {
                Text(resetTime)
                    .font(Theme.Stats.font11Regular)
                    .foregroundColor(Theme.Stats.text3)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 36, alignment: .trailing)
            }
        }
        .frame(height: 16)
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
    let tint: Color
    let warning: Double
    let critical: Double
    let pacePercent: Double?
    let paceOver: Bool

    private var statusColor: Color {
        MetricBar.resolvedColor(
            percent: value * 100,
            warning: warning,
            critical: critical,
            tint: tint
        )
    }

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
                        .fill(statusColor)
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
    static var defaultValue: CGFloat = 20
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
