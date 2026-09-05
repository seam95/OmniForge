import SwiftUI

// MARK: - 网络诊断详情主壳（实用工具详情内嵌）
//
// 顶部分段（网络｜端口）持久化到 UserDefaults；进入详情 onAppear 各自动采一次，
// 切换分段不重采，手动刷新由各分段工具条触发。

private enum NetworkDiagnosticsSegment: String {
    case network
    case ports
}

struct NetworkDiagnosticsView: View {
    let strings: Strings
    @Environment(\.controlCenterSizing) private var sizingContext

    @ObservedObject private var service = NetworkDiagnosticsService.shared
    @AppStorage(UserDefaultsKeys.networkDiagnosticsSegment)
    private var storedSegment = NetworkDiagnosticsSegment.network.rawValue

    @State private var didAutoRefreshOnEnter = false

    private var segment: NetworkDiagnosticsSegment {
        NetworkDiagnosticsSegment(rawValue: storedSegment) ?? .network
    }

    var body: some View {
        // 平面分区：分段行对齐 Token/供应商页节奏（h12、上 2 下 6），内容分区自行持有 h16 v12。
        VStack(alignment: .leading, spacing: 0) {
            PanelSegmentedControl(
                options: [
                    .init(tag: NetworkDiagnosticsSegment.network.rawValue, title: strings.networkDiagnosticsSegmentNetwork),
                    .init(tag: NetworkDiagnosticsSegment.ports.rawValue, title: strings.networkDiagnosticsSegmentPorts)
                ],
                selection: segmentBinding
            )
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 6)

            // 网络/端口平级切换：单活动树分阶段淡出后淡入（SPEC §6）。
            PageSwitchHost(
                requestedRoute: segment,
                semantics: { _, _ in .peer },
                surface: { _ in .clear },
                onRouteMountedBarrier: sizingContext.map { context in
                    { segment, proceed in
                        context.mountStarted(path: "networkdiag/\(segment)", proceed: proceed)
                    }
                }
            ) { segment in
                switch segment {
                case .network:
                    NetworkSegmentView(strings: strings, service: service)
                case .ports:
                    PortSegmentView(strings: strings, service: service)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            // 进入详情：网络 + 端口各自动采一次；分段切换不重采。
            guard !didAutoRefreshOnEnter else { return }
            didAutoRefreshOnEnter = true
            service.refreshNetwork()
            service.refreshPorts()
        }
    }

    private var segmentBinding: Binding<String> {
        Binding(
            get: {
                NetworkDiagnosticsSegment(rawValue: storedSegment)?.rawValue
                    ?? NetworkDiagnosticsSegment.network.rawValue
            },
            set: { storedSegment = $0 }
        )
    }
}
