import SwiftUI

struct MonitorContainerView: View {
    @StateObject var coordinator = ProcessBreakdownCoordinator()
    @StateObject private var diskProtection = DiskProtectionService()
    @State private var route: MonitorPanelRoute = .overview
    /// 设备摘要缓存：Host/sysctl 只在进入面板时算一次，避免随 snapshot 每帧重算。
    @State private var deviceSummary = DeviceSummary(
        hostName: "",
        osVersionText: nil,
        uptimeText: nil
    )
    @ObservedObject private var featureRuntime = FeatureRuntime.shared
    let snapshot: SystemSnapshot
    let history: MetricHistory
    let processState: ProcessBreakdownState
    let speedTestState: SpeedTestState
    let configuration: MonitorConfiguration
    let strings: Strings
    let onDemandChange: (MonitorDemand) -> Void
    let onExpandedMetric: (ProcessMetricKind?) -> Void
    let onStartSpeedTest: () -> Void
    var onOpenSettings: () -> Void = {}
    var showsSettingsAction = true
    /// Refresh callback; `forceProcess` is true on ranking so process Top re-samples past the 4s throttle.
    var onRefresh: (_ forceProcess: Bool) -> Void = { _ in }
    var deviceSummaryProvider: DeviceSummaryProvider = DeviceSummaryProvider()

    var body: some View {
        Group {
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
                    onOpenSettings: onOpenSettings,
                    showsSettingsAction: showsSettingsAction,
                    onRefresh: { onRefresh(false) }
                )
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
            }
        }
        .onAppear {
            coordinator.onToggle = { onExpandedMetric($0) }
            if deviceSummary.hostName.isEmpty {
                deviceSummary = deviceSummaryProvider.makeSummary(
                    fallbackHostName: strings.monitorDeviceFallbackName
                )
            }
            updateDemand()
        }
        // systemMonitor 从 unavailable→available 或 isEnabled 重新打开时，面板仍打开需重新 assert demand
        .onChange(of: featureRuntime.revision) { _, _ in updateDemand() }
        .onChange(of: configuration.isEnabled) { _, _ in updateDemand() }
        .onChange(of: configuration.visibleSections) { _, _ in updateDemand() }
        .onDisappear {
            onDemandChange(.none)
            coordinator.close()
            route = .overview
            coordinator.onToggle = nil
        }
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
