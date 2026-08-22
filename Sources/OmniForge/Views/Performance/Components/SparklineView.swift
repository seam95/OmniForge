import SwiftUI

/// 单序列面积折线 — 用于 CPU/GPU 百分比趋势（domain 0...1）与网络速率趋势。
///
/// 不加隐式动画，随 snapshot 同频直接重绘；空/单点/恒定值由 `SparklineNormalizer` 兜底。
struct SparklineView: View {
    let values: [Double]
    let color: Color
    var domain: ClosedRange<Double> = 0...1
    var lineWidth: CGFloat = 1.5
    var fillHeight: CGFloat = 0.35

    var body: some View {
        GeometryReader { proxy in
            let points = SparklineNormalizer.normalize(values: values, domain: domain)
                .enumerated()
                .map { index, value in
                    CGPoint(
                        x: proxy.size.width * CGFloat(index) / CGFloat(max(pointsCount - 1, 1)),
                        y: proxy.size.height * (1 - value)
                    )
                }

            if points.count >= 2 {
                ZStack {
                    areaPath(points: points, size: proxy.size)
                    linePath(points: points)
                }
            } else if let single = points.first {
                let baselinePoints = [
                    CGPoint(x: 0, y: single.y),
                    CGPoint(x: proxy.size.width, y: single.y)
                ]
                ZStack {
                    areaPath(points: baselinePoints, size: proxy.size)
                    linePath(points: baselinePoints)
                }
            }
        }
    }

    private var pointsCount: Int {
        max(values.count, 1)
    }

    private func linePath(points: [CGPoint]) -> some View {
        Path { path in
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }

    private func areaPath(points: [CGPoint], size: CGSize) -> some View {
        Path { path in
            path.move(to: CGPoint(x: points[0].x, y: size.height))
            path.addLine(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            path.closeSubpath()
        }
        .fill(
            LinearGradient(
                colors: [color.opacity(fillHeight), color.opacity(0.05)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

/// 归一化工具 — 纯函数，独立可测。
enum SparklineNormalizer {
    /// 把值映射到 0...1 绘图坐标。
    /// - 空数组 → 空；单点/恒定值（domain 跨度为零）→ 全部映射到 domain 中点。
    static func normalize(values: [Double], domain: ClosedRange<Double>) -> [Double] {
        guard !values.isEmpty else { return [] }
        let span = domain.upperBound - domain.lowerBound
        guard span > 0, span.isFinite else {
            // 恒定 domain（退化）：取中点，避免除零
            let midpoint = (domain.lowerBound + domain.upperBound) / 2
            return values.map { _ in midpoint }
        }
        return values.map { value in
            let clamped = min(max(value, domain.lowerBound), domain.upperBound)
            return (clamped - domain.lowerBound) / span
        }
    }
}
