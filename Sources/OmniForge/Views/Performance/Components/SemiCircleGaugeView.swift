import SwiftUI

/// 半圆仪表 — 复用 `Circle().trim` 模式：轨道 `trim(0...0.5)` 旋转 180° 得上半圆，
/// 进度 `trim(0...(0.5 * clamp))`。只画弧，居中文本由调用卡通过 overlay 放置。
///
/// 弧的弦（两端点连线）落在视图底边：圆心在底边中点，弧向上隆起。
struct SemiCircleGaugeView: View {
    let progress: Double
    let accent: Color
    var lineWidth: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            // 直径取能容纳上半圆弧的最大值：半径不超过宽一半（不越横界）与高（顶不越界）。
            let diameter = min(proxy.size.width, proxy.size.height * 2)

            ZStack {
                Circle()
                    .trim(from: 0, to: 0.5)
                    .stroke(
                        Color.primary.opacity(0.07),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(180))

                Circle()
                    .trim(from: 0, to: 0.5 * MetricBar.clamp(progress))
                    .stroke(
                        accent,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(180))
            }
            .frame(width: diameter, height: diameter)
            .position(x: proxy.size.width / 2, y: proxy.size.height)
        }
    }
}
