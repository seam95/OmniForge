import Foundation

// MARK: - 模型 Top 列表

/// 模型行：名称 + 窗口 token 总量 + 占全部模型比例（0...100，视图侧 1 位小数）。
struct UsageTopModelEntry: Equatable, Identifiable {
    var id: String { name }
    var name: String
    var tokens: Int
    var percent: Double
}

// MARK: - 模型 Top 构建器

/// 从模型聚合（已按 provider 过滤）派生 Top N — 纯函数。
///
/// 逻辑对齐 TokenTracker `buildTopModels`：只保留 token > 0 的行，
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
