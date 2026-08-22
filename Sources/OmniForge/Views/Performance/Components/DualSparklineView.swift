import SwiftUI

/// 网络双序列镜像图 — 上行红从中线向上、下行绿从中线向下（Activity Monitor 风格）。
///
/// 上下各占半高，共享同一 domain `0...max(up, down, 1)`，避免遮挡。
struct DualSparklineView: View {
    let downValues: [Double]
    let upValues: [Double]

    private var domain: ClosedRange<Double> {
        let peak = max(downValues.max() ?? 0, upValues.max() ?? 0)
        return 0...max(peak, 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let half = proxy.size.height / 2
            ZStack {
                // 下行（绿）从中线向下：默认映射 value=1 在帧顶（中线），垂直翻转后落在底边。
                SparklineView(
                    values: downValues,
                    color: .green,
                    domain: domain,
                    fillHeight: 0.35
                )
                .frame(height: half)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .scaleEffect(x: 1, y: -1)

                // 上行（红）从中线向上：默认映射 value=1 在帧顶即面板顶，无需翻转。
                SparklineView(
                    values: upValues,
                    color: .red,
                    domain: domain,
                    fillHeight: 0.35
                )
                .frame(height: half)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}
