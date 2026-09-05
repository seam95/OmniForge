import Foundation

/// Token 用量分区渲染数据：趋势点与模型 Top **只读** dashboard 快照
/// （SPEC §9.2.2 渲染路径零存储访问）。
///
/// 空序列 / 空列表是该周期无数据的合法结果，不视为缓存未命中；
/// 快照未就绪（nil）时给空展示，由视图占位，不回退查询存储。
struct TokenPanelUsageRenderData: Equatable {
    let dashboard: TokenUsageDashboardSnapshot?
    let period: TokenTrendPeriod

    var trendPoints: [UsageTrendPoint] {
        dashboard?.trendPoints[period] ?? []
    }

    var topModels: [UsageTopModelEntry] {
        dashboard?.topModels[period] ?? []
    }
}
