import Foundation

/// 聚合模式切换后驱动直连激活态重算的边界（依赖倒置：聚合管理器不直连切换管理器）。
///
/// 为什么需要：聚合投影把客户端配置指向本机代理，`ProviderSwitchManager.activeByTool`
/// 是纯内存缓存，进入/退出聚合若不驱动它重算，缓存会停留在切换前的值——
/// 退出聚合恢复文件后，界面仍显示旧激活态（2026-10-17 实测：「未托管配置」横幅残留）。
@MainActor
protocol ProviderActivationRefreshing {
    func refreshActivationState()
}
