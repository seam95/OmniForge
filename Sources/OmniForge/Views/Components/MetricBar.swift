import SwiftUI

/// 指标进度条：把 0.0–1.0 的使用率可视化为细圆角条，并按阈值切换状态色。
/// 默认对标 macOS 活动监视器：满载红、偏高橙、正常绿。
/// 传入 `tint` 时正常段使用该色，warning/critical 仍覆盖为橙/红。
struct MetricBar: View {
    /// 0.0–1.0；越界会被钳制到该区间。
    let value: Double
    /// 转为状态色的百分比阈值（0–100）。
    let warningThreshold: Double
    let criticalThreshold: Double
    /// 正常段强调色；`nil` 时正常段为绿色。
    let tint: Color?

    init(
        value: Double,
        warning: Double = 60,
        critical: Double = 80,
        tint: Color? = nil
    ) {
        self.value = Self.clamp(value)
        self.warningThreshold = warning
        self.criticalThreshold = critical
        self.tint = tint
    }

    /// 将进度钳制到 0…1。
    static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    /// 按百分比与阈值选择条颜色；`tint` 非 nil 时正常段用 tint。
    static func resolvedColor(
        percent: Double,
        warning: Double,
        critical: Double,
        tint: Color?
    ) -> Color {
        if percent >= critical {
            return Theme.Stats.up
        }
        if percent >= warning {
            return Theme.Stats.ram
        }
        return tint ?? Theme.Stats.statusNormal
    }

    private var percent: Double { value * 100 }

    private var statusColor: Color {
        Self.resolvedColor(
            percent: percent,
            warning: warningThreshold,
            critical: criticalThreshold,
            tint: tint
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                // 轨道
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                // 进度
                Capsule()
                    .fill(statusColor)
                    .frame(width: proxy.size.width * value)
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.25), value: value)
        .accessibilityLabel(Text("\(Int(percent))%"))
    }
}
