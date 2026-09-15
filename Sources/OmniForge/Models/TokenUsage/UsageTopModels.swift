import Foundation

// MARK: - Top 列表维度

/// Top 列表聚合维度：按模型（`GROUP BY model`）或按 app（`GROUP BY provider`）。
/// 两维度是同一份用量桶数据的两种 GROUP BY，互不冲突。
enum TokenUsageTopDimension: String, Codable, CaseIterable {
    case model
    case app

    /// 分区标题（随维度切换）。
    func sectionTitle(_ strings: Strings) -> String {
        switch self {
        case .model: return strings.tokenTopModelsTitle
        case .app: return strings.tokenTopAppsTitle
        }
    }

    /// 切换器选项文案。
    func label(_ strings: Strings) -> String {
        switch self {
        case .model: return strings.tokenTopDimensionModel
        case .app: return strings.tokenTopDimensionApp
        }
    }
}

// MARK: - 模型 Top 列表

/// 模型行：名称 + 窗口 token 总量 + 占全部模型比例（0...100，视图侧 1 位小数）。
/// `provider` 仅 App 维度非 nil（行首列渲染品牌 logo）；模型维度保持 nil。
/// 两维度不同屏混排，`id`（= name）无碰撞路径。
struct UsageTopModelEntry: Equatable, Identifiable {
    var id: String { name }
    var name: String
    var tokens: Int
    var percent: Double
    var provider: TokenUsageProvider? = nil
}

// MARK: - 模型 Top 构建器

/// 从模型聚合（已按 provider 过滤）派生 Top N — 纯函数。
///
/// 逻辑：只保留 token > 0 的行，
/// 占比 = 该模型 / 全部模型总量；按总量降序、同名按字典序升序，取前 `limit`。
enum UsageTopModelsBuilder {
    static func make(
        models: [UsageModelAggregate],
        limit: Int = 5
    ) -> [UsageTopModelEntry] {
        let positive = models.filter { $0.totalTokens > 0 }
        guard !positive.isEmpty else { return [] }
        let total = positive.reduce(0) { $0 + $1.totalTokens }
        return positive
            .map { aggregate in
                UsageTopModelEntry(
                    name: aggregate.model,
                    tokens: aggregate.totalTokens,
                    percent: total > 0 ? Double(aggregate.totalTokens) / Double(total) * 100 : 0
                )
            }
            .sorted { lhs, rhs in
                if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
                return lhs.name.localizedCompare(rhs.name) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }
}
