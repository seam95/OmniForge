import Foundation

/// 单个进程的资源使用数据
struct ProcessUsage: Equatable, Identifiable {
    var id: pid_t { pid }
    let pid: pid_t
    let name: String
    /// CPU/GPU: percentage (0–100+). Memory: bytes. Network: total bytes/s.
    let value: Double
    var networkDownBytesPerSec: Double? = nil
    var networkUpBytesPerSec: Double? = nil

    init(
        pid: pid_t,
        name: String,
        value: Double,
        networkDownBytesPerSec: Double? = nil,
        networkUpBytesPerSec: Double? = nil
    ) {
        self.pid = pid
        self.name = name
        self.value = value
        self.networkDownBytesPerSec = networkDownBytesPerSec
        self.networkUpBytesPerSec = networkUpBytesPerSec
    }
}

/// 进程排行状态机 — 一次只能处于一种展开状态
enum ProcessBreakdownState: Equatable {
    case collapsed
    case loading(ProcessMetricKind)
    case loaded(ProcessMetricKind, [ProcessUsage])
    case failed(ProcessMetricKind, String)

    var kind: ProcessMetricKind? {
        switch self {
        case .collapsed: return nil
        case let .loading(kind), let .loaded(kind, _), let .failed(kind, _): return kind
        }
    }
}

/// 占用排行展示条数契约：采样与 UI 共用，避免两处硬编码漂移。
enum ProcessRankingDisplay {
    static let limit = 30
}
