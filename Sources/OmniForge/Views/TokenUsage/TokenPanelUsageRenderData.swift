import Foundation

/// Token 用量分区渲染数据：趋势点与 Top 列表（模型 / App 维度）**只读** dashboard 快照
/// （SPEC §9.2.2 渲染路径零存储访问）。
///
/// 空序列 / 空列表是该周期无数据的合法结果，不视为缓存未命中；
/// 快照未就绪（nil）时给空展示，由视图占位，不回退查询存储。
struct TokenPanelUsageRenderData: Equatable {
    let dashboard: TokenUsageDashboardSnapshot?
    let period: TokenTrendPeriod
    /// Top 列表聚合维度（默认模型，保持既有构造点兼容）。
    var dimension: TokenUsageTopDimension = .model

    var trendPoints: [UsageTrendPoint] {
        dashboard?.trendPoints[period] ?? []
    }

    var topModels: [UsageTopModelEntry] {
        dashboard?.topModels[period] ?? []
    }

    var topProviders: [UsageTopModelEntry] {
        dashboard?.topProviders[period] ?? []
    }

    /// 当前维度下的 Top 列表。
    var topEntries: [UsageTopModelEntry] {
        switch dimension {
        case .model: return topModels
        case .app: return topProviders
        }
    }
}
