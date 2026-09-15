import Foundation

enum MonitorPanelRoute: Equatable {
    case overview
    case ranking(ProcessMetricKind)
    case diskDetail
}
