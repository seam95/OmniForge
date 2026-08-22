import SwiftUI

/// 单个 provider 的限额卡：头部（色块 + 名称 + 订阅计划 + 状态徽章）+ 窗口行（名称 / 百分比 /
/// 进度条 + 步速刻度 + 说明行）。错误态时卡片体降级为错误说明行。
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
        [.session, .weekly, .monthly, .credits].compactMap { kind in
            limits.windows[kind].map { (kind, $0) }
        }
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
            } else if orderedWindows.isEmpty {
                errorRow(.decoding("empty windows"))
            } else {
                windowsBody
            }
        }
        .padding(12)
        .omniCardStyle()
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
        VStack(alignment: .leading, spacing: 8) {
            ForEach(orderedWindows.indices, id: \.self) { index in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.Stats.separator)
                        .frame(height: 0.5)
                        .padding(.vertical, 2)
                }
                windowRow(orderedWindows[index].kind, window: orderedWindows[index].window)
            }
        }
    }

    private func windowRow(_ kind: LimitWindowKind, window: UsageWindow) -> some View {
        let pace = computePace(kind: kind, window: window)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(kind.title(strings))
                    .font(Theme.Stats.font11Regular)
                    .foregroundColor(Theme.Stats.text2)
                Spacer()
                Text(valueText(kind: kind, window: window))
                    .font(Theme.Stats.font12Medium)
                    .foregroundColor(Theme.Stats.text1)
                    .monospacedDigit()
            }
            LimitBarWithPace(
                value: window.usedPercent / 100,
                tint: kind == .credits ? Theme.Stats.statusNormal : limits.provider.accentColor,
                warning: kind == .credits ? 101 : 70,
                critical: kind == .credits ? 102 : 85,
                pacePercent: pace.pacePercent,
                paceOver: pace.paceOver
            )
            captionRow(kind: kind, window: window, pace: pace)
        }
    }

    /// 窗口行值：额度窗固定「剩 $x」口径；其余按设置切换已用 / 剩余百分比。
    private func valueText(kind: LimitWindowKind, window: UsageWindow) -> String {
        if kind == .credits, let remaining = window.remaining {
            return String(
                format: strings.tokenCreditsRemainingFormat,
                currencyPrefix(for: window.unit) + String(format: "%.2f", remaining)
            )
        }
        let shown = displayMode == .used ? window.usedPercent : max(0, 100 - window.usedPercent)
        return TokenUsageFormat.percent(shown)
    }

    /// 额度货币前缀：USD → "$"，其他按代码 + 空格。
    private func currencyPrefix(for unit: String?) -> String {
        guard let unit = unit?.uppercased() else { return "$" }
        if unit.contains("USD") { return "$" }
        return "\(unit) "
    }

    private func captionRow(kind: LimitWindowKind, window: UsageWindow, pace: LimitPace.Result) -> some View {
        HStack(spacing: 4) {
            if pace.paceOver {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.Stats.ram)
            }
            Text(TokenUsageFormat.caption(for: window, kind: kind, pace: pace, now: now, strings: strings))
                .font(Theme.Stats.font10Regular)
                .foregroundColor(Theme.Stats.text2)
        }
    }

    private func computePace(kind: LimitWindowKind, window: UsageWindow) -> LimitPace.Result {
        guard kind != .credits else { return LimitPace.Result() }
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

/// 进度条 + 步速刻度：刻度以细竖线跨在条上（超前红 / 正常绿），位置 = 期望用量百分比。
private struct LimitBarWithPace: View {
    let value: Double
    let tint: Color
    let warning: Double
    let critical: Double
    let pacePercent: Double?
    let paceOver: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                MetricBar(value: value, warning: warning, critical: critical, tint: tint)
                if let pacePercent {
                    Rectangle()
                        .fill(paceOver ? Theme.Stats.up : Theme.Stats.statusNormal)
                        .frame(width: 2, height: 8)
                        .offset(x: proxy.size.width * min(max(pacePercent, 0), 100) / 100 - 1)
                }
            }
        }
        .frame(height: 8)
    }
}
