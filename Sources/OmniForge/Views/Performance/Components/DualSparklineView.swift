import SwiftUI

/// 网络双序列走势图 — 下行绿线与上行红线在同一坐标域内全幅绘制。
///
/// 共享 domain `0...max(up, down, 1)`：上行通常远小于下行，自然沉在下方区域。
/// 上行线降低不透明度以区分主次；下行右端圆点标记最新值。
struct DualSparklineView: View {
    let downValues: [Double]
    let upValues: [Double]
    var lineWidth: CGFloat = 1.4

    private var domain: ClosedRange<Double> {
        let peak = max(downValues.max() ?? 0, upValues.max() ?? 0)
        return 0...max(peak, 1)
    }

    var body: some View {
        ZStack {
            SparklineView(
                values: upValues,
                color: Theme.Stats.up.opacity(0.55),
                domain: domain,
                lineWidth: lineWidth,
                fillHeight: 0
            )
            SparklineView(
                values: downValues,
                color: Theme.Stats.down,
                domain: domain,
                lineWidth: lineWidth,
                fillHeight: 0,
                endDotRadius: 2.2
            )
        }
    }
}
