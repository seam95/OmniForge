import SwiftUI

struct MonitorContainerView: View {
    /// 由宿主注入：切走面板时本视图销毁，这两个有状态对象不随之重建
    /// （保留磁盘推出进度与已展开的进程指标）。
    @ObservedObject var coordinator: ProcessBreakdownCoordinator
    @ObservedObject var diskProtection: DiskProtectionService
    /// 路由由宿主持有：面板切换回来保留所在层级（overview / 排名 / 磁盘详情）。
    @Binding var route: MonitorPanelRoute
    /// 设备摘要缓存：Host/sysctl 只在进入面板时算一次，避免随 snapshot 每帧重算。
    @State private var deviceSummary = DeviceSummary(
        hostName: "",
        osVersionText: nil,
        uptimeText: nil
    )
    @ObservedObject private var featureRuntime = FeatureRuntime.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlCenterSizing) private var sizingContext

    /// 监控运行时直连观察（SPEC §9.4.2）：快照/历史/进程/测速状态由本页面
    /// 自行订阅刷新，不再经 AppState 转发驱动控制中心根视图重算。
    @ObservedObject var monitor: SystemMonitorManager
    let configuration: MonitorConfiguration
    let strings: Strings
    /// 配置变化（分区/开关/可用性）时重断言采样需求；route 级的面板需求
    /// 由控制中心宿主协调（SPEC §9.1.1）。
    let onDemandChange: (MonitorDemand) -> Void
    let onExpandedMetric: (ProcessMetricKind?) -> Void
    let onStartSpeedTest: () -> Void
    var onOpenSettings: () -> Void = {}
    var showsSettingsAction = true
    /// Refresh callback; `forceProcess` is true on ranking so process Top re-samples past the 4s throttle.
    var onRefresh: (_ forceProcess: Bool) -> Void = { _ in }
    var deviceSummaryProvider: DeviceSummaryProvider = DeviceSummaryProvider()
    /// 页面树挂载计数观测（测试配置用；+1 onAppear / -1 onDisappear，携带页面 route）。
    /// 用于在真实监控层级切换上断言单活动树不变量（SPEC §6.3.5）。
    var pageMountObserver: (@MainActor (MonitorPanelRoute, Int) -> Void)? = nil

    var body: some View {
        // 层级页面统一 Host（SPEC §5/§6）：overview → 排名/磁盘详情为前进，
        // 返回 overview 为后退；小幅位移 + 淡出后淡入（4pt/12pt，Reduce Motion 归零）。
        PageSwitchHost(
            requestedRoute: route,
            semantics: Self.semantics,
            surface: pageSurface,
            onRouteMountedBarrier: sizingContext.map { context in
                { route, proceed in
                    context.mountStarted(path: "monitor/\(route)", proceed: proceed)
                }
            }
        ) { currentRoute in
            content(for: currentRoute)
        }
        .onAppear {
            coordinator.onToggle = { onExpandedMetric($0) }
            if deviceSummary.hostName.isEmpty {
                deviceSummary = deviceSummaryProvider.makeSummary(
                    fallbackHostName: strings.monitorDeviceFallbackName
                )
            }
            // 面板切回时若仍停在排名 route，恢复对应进程采样
            // （切走时 onDisappear 已 close，此处 onToggle 已绑定）。
            if let kind = Self.rankingRestoration(for: route) {
                coordinator.open(kind)
            }
        }
        .onDisappear {
            // 本内容树卸载 = 离开监控面板或切到其他层级；折叠进程采样状态
            // 并断开 toggle 绑定。面板级指标采样由宿主 route 协调，不受影响。
            coordinator.close()
            coordinator.onToggle = nil
        }
        // 配置变化（展示分区/开关/功能可用性）重断言采样需求。
        .onChange(of: featureRuntime.revision) { _, _ in updateDemand() }
        .onChange(of: configuration.isEnabled) { _, _ in updateDemand() }
        .onChange(of: configuration.visibleSections) { _, _ in updateDemand() }
    }

    /// 层级方向语义：进子页为前进、回 overview 为后退（SPEC §7.3.5）。
    static func semantics(from: MonitorPanelRoute, to: MonitorPanelRoute) -> PageSwitchSemantics {
        if from == .overview { return .forward }
        if to == .overview { return .backward }
        return .peer // 排名与磁盘详情之间无直达路径，防御性兜底
    }

    /// 页面表面：overview 浅色平面白底，其余透明（露面板灰底）。
    private func pageSurface(_ page: MonitorPanelRoute) -> PageSurface {
        if colorScheme == .light && page == .overview {
            return PageSurface(background: .white)
        }
        return .clear
    }

    @ViewBuilder
    private func content(for page: MonitorPanelRoute) -> some View {
        switch page {
        case .overview:
            MonitorOverviewView(
                snapshot: monitor.snapshot,
                history: monitor.history,
                configuration: configuration,
                strings: strings,
                deviceSummary: deviceSummary,
                onSelectRankable: { kind in
                    coordinator.open(kind)
                    route = .ranking(kind)
                },
                onSelectDiskDetail: {
                    route = .diskDetail
                },
                onRefresh: { onRefresh(false) }
            )
            .pageMountReporting(.overview, observer: pageMountObserver)
        case .diskDetail:
            MonitorDiskDetailView(
                snapshot: monitor.snapshot,
                strings: strings,
                temperatureUnit: configuration.temperatureUnit,
                protection: diskProtection,
                onBack: { route = .overview },
                onOpenSettings: onOpenSettings,
                showsSettingsAction: showsSettingsAction,
                onRefresh: { onRefresh(false) }
            )
            .pageMountReporting(.diskDetail, observer: pageMountObserver)
        case .ranking(let kind):
            MonitorRankingView(
                kind: kind,
                state: monitor.processState,
                strings: strings,
                onBack: {
                    coordinator.close()
                    route = .overview
                },
                onOpenSettings: onOpenSettings,
                showsSettingsAction: showsSettingsAction,
                onRefresh: { onRefresh(true) }
            )
            .pageMountReporting(page, observer: pageMountObserver)
        }
    }

    /// 切回面板时需恢复采样的排名指标；nil 表示无需恢复。
    static func rankingRestoration(for route: MonitorPanelRoute) -> ProcessMetricKind? {
        if case .ranking(let kind) = route { return kind }
        return nil
    }

    private func updateDemand() {
        onDemandChange(Self.demand(for: configuration))
    }

    /// 平铺布局：对所有可见分区聚合采样需求（隐藏即停止采样）
    static func demand(for configuration: MonitorConfiguration) -> MonitorDemand {
        let visible = configuration.visibleSections
        var demand = MonitorDemand()
        if visible.contains(.system) {
            demand.system = true
            demand.cpu = true
            demand.gpu = true
            demand.memory = true
        }
        if visible.contains(.network) {
            demand.network = true
        }
        if visible.contains(.disk) {
            demand.disk = true
        }
        if visible.contains(.power) {
            demand.power = true
        }
        return demand
    }
}

/// 页面挂载上报：挂在类型不同的真实页面分支上（身份天然区分），
/// 供测试在真实监控层级切换上断言单活动树（SPEC §6.3.5）。
private extension View {
    @ViewBuilder
    func pageMountReporting(
        _ page: MonitorPanelRoute,
        observer: (@MainActor (MonitorPanelRoute, Int) -> Void)?
    ) -> some View {
        if let observer {
            onAppear { observer(page, 1) }
                .onDisappear { observer(page, -1) }
        } else {
            self
        }
    }
}
