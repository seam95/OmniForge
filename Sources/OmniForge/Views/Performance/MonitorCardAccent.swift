import SwiftUI

/// 监控卡片强调色 — 固定配色，不随使用率阈值变化；仅电池保留低电量红/橙告警色。
enum MonitorCardAccent {
    /// 卡片主色（圆点/图标/可视化）。
    static func color(for id: MonitorCardID) -> Color {
        switch id {
        case .cpu: return .blue
        case .memory: return .orange
        case .network: return .green
        case .battery: return .green
        case .gpu: return .purple
        case .disk: return .blue
        case .energy: return .yellow
        }
    }

    /// 网络上传方向固定红（下行绿见 `.network`）。
    static let networkUpload = Color.red

    /// 进度可视化配色：仅电池保留低电量红/橙，其余一律固定主色。
    static func barTint(for id: MonitorCardID, progress: Double) -> Color {
        if id == .battery {
            let percent = MetricBar.clamp(progress) * 100
            if percent <= 15 { return .red }
            if percent <= 35 { return .orange }
        }
        return color(for: id)
    }
}
