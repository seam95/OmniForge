import SwiftUI

/// 监控卡片强调色 — Stats Light 规范固定配色，不随使用率阈值变化；仅电池保留低电量红/橙告警色。
enum MonitorCardAccent {
    /// 卡片主色（色块/图标/可视化）。
    static func color(for id: MonitorCardID) -> Color {
        switch id {
        case .cpu: return Theme.Stats.cpu
        case .memory: return Theme.Stats.ram
        case .network: return Theme.Stats.down
        case .battery: return Theme.Stats.battery
        case .gpu: return Theme.Stats.gpu
        case .disk: return Theme.Stats.cpu
        case .energy: return Theme.Stats.ram
        }
    }

    /// 网络上传方向固定红（下行绿见 `.network`）。
    static let networkUpload = Theme.Stats.up

    /// 状态正常徽章色
    static let statusNormal = Theme.Stats.statusNormal

    /// 进度可视化配色：仅电池保留低电量红/橙，其余一律固定主色。
    static func barTint(for id: MonitorCardID, progress: Double) -> Color {
        if id == .battery {
            let percent = MetricBar.clamp(progress) * 100
            if percent <= 15 { return Theme.Stats.up }
            if percent <= 35 { return Theme.Stats.ram }
        }
        return color(for: id)
    }
}

