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

    /// 附加带标签窗口（Claude Opus/scoped、Cursor 车道、Codex Spark、Antigravity Gemini 双窗）。
    private var labeledWindows: [LabeledUsageWindow] {
        limits.labeledWindows ?? []
    }

    /// 重置权益区可见性：有可展示条目（明细行或 count）才显示。
    private var showsResetBank: Bool {
        guard let bank = limits.resetBank else { return false }
        if !bank.credits.isEmpty { return true }
        return (bank.displayCount ?? 0) > 0
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
                if showsResetBank {
                    resetBankSection
                }
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
                    windowSeparator
                }
                windowRow(orderedWindows[index].kind, window: orderedWindows[index].window)
            }
        }
    }

    /// 附加带标签窗口行：标题用 label + 重置时间，进度条同主窗样式；无 kind → 不画 pace 刻度。
    /// 注意：labeled 窗固定按已用口径展示数值（无 kind，剩余换算可能产生负数/误导）。
    private var labeledWindowsBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !orderedWindows.isEmpty {
                windowSeparator
            }
            ForEach(labeledWindows.indices, id: \.self) { index in
                if index > 0 {
                    windowSeparator
                }
                let entry = labeledWindows[index]
                let resetTime = TokenUsageFormat.windowResetTime(resetAt: entry.window.resetAt, now: now)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.label)
                            .font(Theme.Stats.font11Regular)
                            .foregroundColor(Theme.Stats.text2)
                        if let resetTime {
                            Text(resetTime)
                                .font(Theme.Stats.font11Regular)
                                .foregroundColor(Theme.Stats.text3)
                        }
                        Spacer()
                        // labeled 窗固定按已用口径展示（无 kind，剩余换算可能产生负数/误导）。
                        Text(TokenUsageFormat.percent(entry.window.usedPercent))
                            .font(Theme.Stats.font12Medium)
                            .foregroundColor(Theme.Stats.text1)
                            .monospacedDigit()
                    }
                    MetricBar(
                        value: TokenUsageFormat.limitBarProgress(for: entry.window),
                        warning: 70,
                        critical: 90,
                        tint: limits.provider.accentColor
                    )
                }
            }
        }
    }

    /// 重置权益区（Codex）：标题 + 每条可用权益一行「重置 N · 过期时间」；
    /// 有 count 无明细时显示次数行；无可展示项时整区不出现。
    @ViewBuilder
    private var resetBankSection: some View {
        let bank = limits.resetBank
        VStack(alignment: .leading, spacing: 6) {
            windowSeparator
            Text(strings.tokenResetBankTitle)
                .font(Theme.Stats.font11Regular)
                .foregroundColor(Theme.Stats.text2)
            if let credits = bank?.credits, !credits.isEmpty {
                ForEach(credits.indices, id: \.self) { index in
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.Stats.statusNormal)
                        Text(String(
                            format: strings.tokenResetBankEntryFormat,
                            index + 1,
                            TokenUsageFormat.duration(credits[index].expiresAt.timeIntervalSince(now), strings: strings)
                        ))
                        .font(Theme.Stats.font10Regular)
                        .foregroundColor(Theme.Stats.text2)
                    }
                }
            } else if let count = bank?.displayCount, count > 0 {
                Text(String(format: strings.tokenResetBankCountOnlyFormat, count))
                    .font(Theme.Stats.font10Regular)
                    .foregroundColor(Theme.Stats.text2)
            }
        }
    }

    private var windowSeparator: some View {
        Rectangle()
            .fill(Theme.Stats.separator)
            .frame(height: 0.5)
            .padding(.vertical, 2)
    }

    private func windowRow(_ kind: LimitWindowKind, window: UsageWindow) -> some View {
        let pace = computePace(kind: kind, window: window)
        let resetTime = TokenUsageFormat.windowResetTime(resetAt: window.resetAt, now: now)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(kind.title(strings))
                    .font(Theme.Stats.font11Regular)
                    .foregroundColor(Theme.Stats.text2)
                if let resetTime {
                    Text(resetTime)
                        .font(Theme.Stats.font11Regular)
                        .foregroundColor(Theme.Stats.text3)
                }
                Spacer()
                Text(TokenUsageFormat.limitValueText(kind: kind, window: window, displayMode: displayMode, strings: strings))
                    .font(Theme.Stats.font12Medium)
                    .foregroundColor(Theme.Stats.text1)
                    .monospacedDigit()
            }
            // 条固定表达「已用消耗进度」：染色与填充始终按 usedPercent，
            // 与行内数值的显示口径（used/remaining）解耦——条满 = 用完 = 危险。
            LimitBarWithPace(
                value: TokenUsageFormat.limitBarProgress(for: window),
                tint: kind == .credits ? Theme.Stats.statusNormal : limits.provider.accentColor,
                warning: kind == .credits ? 101 : 70,
                critical: kind == .credits ? 102 : 90,
                pacePercent: pace.pacePercent,
                paceOver: pace.paceOver
            )
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
                    RoundedRectangle(cornerRadius: 1)
                        .fill(paceOver ? Theme.Stats.up : Theme.Stats.statusNormal)
                        .frame(width: 2, height: 10)
                        .offset(x: proxy.size.width * min(max(pacePercent, 0), 100) / 100 - 1)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 10)
    }
}
