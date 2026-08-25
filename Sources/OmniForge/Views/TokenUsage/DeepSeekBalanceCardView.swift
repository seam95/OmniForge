import SwiftUI

/// 控制中心「Token」页的 DeepSeek 余额区块（去卡片化透明布局）：16x16 品牌图标 + 标题 + 右侧总金额、
/// 多币种列表（如适用）与错误行。
struct DeepSeekBalanceCardView: View {
    let snapshot: DeepSeekBalanceSnapshot?
    /// 低余额阈值（面板从偏好注入，徽章「低于阈值」口径与通知一致）。
    let threshold: Double
    let strings: Strings
    let now: Date

    private var status: DeepSeekBalanceCardState {
        DeepSeekBalanceCardState.derive(snapshot: snapshot ?? DeepSeekBalanceSnapshot(
            configured: true, isAvailable: false, infos: [], capturedAt: now, stale: false, issue: nil
        ), threshold: threshold)
    }

    /// DeepSeek 品牌色。
    static let brandColor = Color(red: 0x4D / 255.0, green: 0x6B / 255.0, blue: 0xF5 / 255.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let snapshot {
                if snapshot.issue != nil && snapshot.infos.isEmpty && !snapshot.stale {
                    // 从未成功：无数值可展示，只渲染错误行
                    errorRow(snapshot.issue!)
                } else {
                    currencyBody(snapshot)
                    if let issue = snapshot.issue {
                        errorRow(issue) // 有旧值保留时的行内错误提示
                    }
                }
            } else {
                // 已配置但首拉尚未完成
                Text(strings.deepSeekBalanceLoading)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(Theme.Stats.text3)
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            TokenUsageProviderIconView(provider: .deepSeek, size: 16, cornerRadius: 4)
            Text(strings.deepSeekBalanceCardTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.Stats.text1)
            Spacer()
            if let primaryBalance = primaryTotalBalanceText {
                Text(primaryBalance)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.Stats.text1)
                    .monospacedDigit()
            }
        }
    }

    private var primaryTotalBalanceText: String? {
        guard let snapshot, snapshot.infos.count <= 1, let first = snapshot.infos.first else { return nil }
        return DeepSeekBalanceFormat.amount(first.totalBalance, rawText: first.totalBalanceText, currency: first.currency)
    }

    // MARK: - 币种明细

    @ViewBuilder
    private func currencyBody(_ snapshot: DeepSeekBalanceSnapshot) -> some View {
        let infos = snapshot.infos
        if infos.count > 1 {
            // 多币种展示
            VStack(alignment: .leading, spacing: 4) {
                ForEach(infos.indices, id: \.self) { index in
                    if index > 0 {
                        currencySeparator
                    }
                    currencyRow(infos[index])
                }
            }
        }
    }

    private func currencyRow(_ info: DeepSeekBalanceInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(info.currency)
                .font(Theme.Stats.font11Regular)
                .foregroundColor(Theme.Stats.text2)
            Spacer()
            Text(DeepSeekBalanceFormat.amount(info.totalBalance, rawText: info.totalBalanceText, currency: info.currency))
                .font(Theme.Stats.font12Medium)
                .foregroundColor(Theme.Stats.text1)
                .monospacedDigit()
        }
    }

    private var currencySeparator: some View {
        Rectangle()
            .fill(Theme.Stats.separator)
            .frame(height: 0.5)
            .padding(.vertical, 1)
    }

    // MARK: - 错误
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

// MARK: - 状态派生

/// 余额卡状态：错误优先（与 `TokenUsageCardStatus.derive` 同序），
/// 其次低余额（≥ 阈值下探），再次不可用，正常兜底。
enum DeepSeekBalanceCardState: Equatable {
    case normal
    case belowThreshold
    case unavailable
    case reauth
    case rateLimited
    case stale
    case transient

    static func derive(snapshot: DeepSeekBalanceSnapshot, threshold: Double) -> DeepSeekBalanceCardState {
        if let issue = snapshot.issue {
            switch issue {
            case .reauthRequired: return .reauth
            case .rateLimited: return .rateLimited
            case .network, .decoding:
                // 显示 last-good 快照 + 行内错误提示 → 徽章强调数据可能过期
                return snapshot.stale && !snapshot.infos.isEmpty ? .stale : .transient
            }
        }
        let response = DeepSeekBalanceResponse(isAvailable: snapshot.isAvailable, infos: snapshot.infos)
        if DeepSeekLowBalanceEvaluator.crossedThreshold(in: response, threshold: threshold) {
            return .belowThreshold
        }
        return snapshot.isAvailable ? .normal : .unavailable
    }

    func label(_ strings: Strings) -> String {
        switch self {
        case .normal: return strings.tokenStatusNormal
        case .belowThreshold: return strings.deepSeekStatusBelowThreshold
        case .unavailable: return strings.deepSeekBalanceUnavailable
        case .reauth: return strings.deepSeekStatusReauthKey
        case .rateLimited: return strings.tokenStatusRateLimited
        case .stale: return strings.tokenStatusStale
        case .transient: return strings.tokenErrorTransient
        }
    }

    var tint: Color {
        switch self {
        case .normal: return Theme.Stats.statusNormal
        case .belowThreshold, .unavailable, .rateLimited, .stale: return Theme.Stats.ram
        case .reauth: return Theme.Stats.up
        case .transient: return Theme.Stats.text3
        }
    }

    var showsWarningIcon: Bool {
        self != .normal
    }
}
