import Foundation

// MARK: - 用量分布快照

/// 分布行：一行 = 一个模型或一个 provider 的周期 token 总量。
///
/// 隐私红线（SPEC 2.6）：只携带名称与计数，不含任何会话内容。
struct UsageDistributionEntry: Equatable, Identifiable {
    /// 行内稳定 id：模型名或 provider 展示名（区内唯一）。
    var id: String { label }

    /// 展示名：模型原始名，或 provider 展示名。
    var label: String
    /// nil = 该 provider 行态「无数据」：右值灰显 `--`（SPEC 4.2；
    /// 仅云端口径的 Cursor 占位行会出现，见 `UsageDistributionBuilder`）。
    var totalTokens: Int?
    /// 非 nil = 「按 Provider」行（用 provider 模块色渲染）；nil = 「按模型」行（统一蓝色）。
    var provider: TokenUsageProvider?

    init(label: String, totalTokens: Int?, provider: TokenUsageProvider? = nil) {
        self.label = label
        self.totalTokens = totalTokens
        self.provider = provider
    }
}

/// 分布卡快照：按模型 / 按 Provider 两区（各自降序）。
struct UsageDistribution: Equatable {
    var byModel: [UsageDistributionEntry]
    var byProvider: [UsageDistributionEntry]
}

/// 从半小时桶构建分布卡快照 — 纯函数。
///
/// 语义：
/// - 只统计选中周期窗口（`UsagePeriodWindow`）内的桶；
/// - 两区各自按 token 总量降序，并列时保持确定性（模型按名字典序、provider 按目录序）；
/// - 只有窗口内存在数据才返回非 nil（无数据时整块隐藏，SPEC 4.3）。
/// - 不做 Claude 特化：谁有数据谁出现，后续 provider 自动填充（#07/#08/#09）。
/// - **Cursor 云端口径占位行**（#09）：`configuredProviders` 中已配置但窗口内无数据的
///   Cursor 追加占位行（`totalTokens = nil`，行内右值灰显 `--` + 徽标）；
///   仅 Cursor（无本地日志、非实时）有该特殊行，其他 provider 无数据不出现。
enum UsageDistributionBuilder {
    static func make(
        buckets: [UsageBucketState],
        now: Date,
        calendar: Calendar,
        period: TokenUsagePeriod,
        configuredProviders: [TokenUsageProvider] = []
    ) -> UsageDistribution? {
        guard let window = UsagePeriodWindow.window(for: period, now: now, calendar: calendar) else {
            return nil
        }
        let inWindow = buckets.filter {
            $0.key.bucketStart >= window.start && $0.key.bucketStart < window.end
        }
        guard !inWindow.isEmpty else { return nil }

        var modelTotals: [String: Int] = [:]
        var providerTotals: [TokenUsageProvider: Int] = [:]
        for state in inWindow {
            modelTotals[state.key.model, default: 0] += state.usage.totalTokens
            providerTotals[state.key.provider, default: 0] += state.usage.totalTokens
        }

        let byModel = modelTotals
            .map { UsageDistributionEntry(label: $0.key, totalTokens: $0.value) }
            .sorted { lhs, rhs in
                lhs.totalTokens != rhs.totalTokens
                    ? lhs.totalTokens! > rhs.totalTokens!
                    : lhs.label < rhs.label
            }
        var byProvider = providerTotals
            .map { UsageDistributionEntry(label: $0.key.displayName, totalTokens: $0.value, provider: $0.key) }
            .sorted { lhs, rhs in
                guard let left = lhs.provider, let right = rhs.provider else { return false }
                return lhs.totalTokens != rhs.totalTokens
                    ? lhs.totalTokens! > rhs.totalTokens!
                    : providerOrder(left) < providerOrder(right)
            }
        // Cursor 云端口径占位行：已配置且窗口内无数据 → 追加（非实时，用户已知其脆弱仍保留；
        // 与数据行并存时排在最后，不挤占真实数据）。
        for provider in configuredProviders
        where provider == .cursor && providerTotals[provider] == nil && !byProvider.contains(where: { $0.provider == provider }) {
            byProvider.append(UsageDistributionEntry(label: provider.displayName, totalTokens: nil, provider: provider))
        }
        return UsageDistribution(byModel: byModel, byProvider: byProvider)
    }

    private static func providerOrder(_ provider: TokenUsageProvider) -> Int {
        TokenUsageProvider.allCases.firstIndex(of: provider) ?? -1
    }
}
