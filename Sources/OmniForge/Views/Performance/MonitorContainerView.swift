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
    let snapshot: SystemSnapshot
    let history: MetricHistory
    let processState: ProcessBreakdownState
    let speedTestState: SpeedTestState
    let configuration: MonitorConfiguration
    let strings: Strings
    /// 配置变化（分区/开关/可用性）时重断言采样需求；route 级的面板需求
    /// 由控制中心宿主协调（SPEC §9.1.1），本视图不再挂 onAppear/onDisappear 生命周期。
    let onDemandChange: (MonitorDemand) -> Void
    let onExpandedMetric: (ProcessMetricKind?) -> Void
    let onStartSpeedTest: () -> Void
    var onOpenSettings: () -> Void = {}
    var showsSettingsAction = true
    /// Refresh callback; `forceProcess` is true on ranking so process Top re-samples past the 4s throttle.
    var onRefresh: (_ forceProcess: Bool) -> Void = { _ in }
    var deviceSummaryProvider: DeviceSummaryProvider = DeviceSummaryProvider()

    var body: some View {
        // ZStack 承载层级推入转场：子页自右滑入、回 overview 自左滑回。
        ZStack {
            switch route {
            case .overview:
                MonitorOverviewView(
                    snapshot: snapshot,
                    history: history,
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
                .pushTransition(from: .leading)
            case .diskDetail:
                MonitorDiskDetailView(
                    snapshot: snapshot,
                    strings: strings,
                    temperatureUnit: configuration.temperatureUnit,
                    protection: diskProtection,
                    onBack: { route = .overview },
                    onOpenSettings: onOpenSettings,
                    showsSettingsAction: showsSettingsAction,
                    onRefresh: { onRefresh(false) }
                )
                .pushTransition(from: .trailing)
            case .ranking(let kind):
                MonitorRankingView(
                    kind: kind,
                    state: processState,
                    strings: strings,
                    onBack: {
                        coordinator.close()
                        route = .overview
                    },
                    onOpenSettings: onOpenSettings,
                    showsSettingsAction: showsSettingsAction,
                    onRefresh: { onRefresh(true) }
                )
                .pushTransition(from: .trailing)
            }
        }
        .animation(Theme.Animation.pageTransition, value: route)
        // overview 的平面白底挂在转场容器层而非内容根部：转场容器高度可能比
        // 内容固有高度略大，背景只盖内容根时底部余量会透出面板灰底（底部灰带）。
        .background(colorScheme == .light && route == .overview ? Color.white : Color.clear)
        .onAppear {
            coordinator.onToggle = { onExpandedMetric($0) }
            if deviceSummary.hostName.isEmpty {
                deviceSummary = deviceSummaryProvider.makeSummary(
                    fallbackHostName: strings.monitorDeviceFallbackName
                )
            }
        }
        // 配置变化（展示分区/开关/功能可用性）重断言采样需求；route 级的
        // 面板需求由控制中心宿主协调（SPEC §9.1.1），本视图不再经
        // onAppear/onDisappear 驱动采样生命周期。
        .onChange(of: featureRuntime.revision) { _, _ in updateDemand() }
        .onChange(of: configuration.isEnabled) { _, _ in updateDemand() }
        .onChange(of: configuration.visibleSections) { _, _ in updateDemand() }
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
