import Foundation

/// Token 仪表盘不可变展示快照（SPEC §9.2）：UI 渲染只读此内存对象，
/// 不在 body / onAppear 中发起 SQLite 或 Keychain 访问。
/// 全部趋势周期一次算齐，周期切换只换字典键，不触发重建。
struct TokenUsageDashboardSnapshot: Equatable {
    /// 汇总指标（今日/7天/30天/总计）。
    var summaryCards: UsageSummaryCards
    /// 活跃度年度热力图；nil = 无数据（视图显示占位）。
    var heatmap: UsageActivityHeatmap?
    /// 各趋势周期点集。
    var trendPoints: [TokenTrendPeriod: [UsageTrendPoint]]
    /// 各趋势周期 Top Models。
    var topModels: [TokenTrendPeriod: [UsageTopModelEntry]]
    var updatedAt: Date
}
