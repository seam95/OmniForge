import SwiftUI

/// 单序列折线 — 用于 CPU/GPU/内存百分比趋势（domain 0...1）与网络速率趋势。
///
/// 不加隐式动画，随 snapshot 同频直接重绘；空/单点/恒定值由 `SparklineNormalizer` 兜底。
/// `fillHeight > 0` 时线下叠面积渐变；`endDotRadius > 0` 时在右端点画圆点标记最新值。
struct SparklineView: View {
    let values: [Double]
    let color: Color
    var domain: ClosedRange<Double> = 0...1
    var lineWidth: CGFloat = 1.5
    var fillHeight: CGFloat = 0.18
    var endDotRadius: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let points = resolvedPoints(size: proxy.size)

            if points.count >= 2 {
                ZStack {
                    if fillHeight > 0 {
                        areaPath(points: points, size: proxy.size)
                    }
                    linePath(points: points)
                    if endDotRadius > 0, let tip = points.last {
                        Circle()
                            .fill(color)
                            .frame(width: endDotRadius * 2, height: endDotRadius * 2)
                            .position(tip)
                    }
                }
            }
        }
    }

    /// 归一化并映射到视图坐标；单点补成水平基线，不足两点返回原样（不绘制）。
    private func resolvedPoints(size: CGSize) -> [CGPoint] {
        let normalized = SparklineNormalizer.normalize(values: values, domain: domain)
        var points = normalized.enumerated().map { index, value in
            CGPoint(
                x: size.width * CGFloat(index) / CGFloat(max(normalized.count - 1, 1)),
                y: size.height * (1 - value)
            )
        }
        if points.count == 1, let single = points.first {
            points = [
                CGPoint(x: 0, y: single.y),
                CGPoint(x: size.width, y: single.y)
            ]
        }
        return points
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
                colors: [color.opacity(fillHeight), color.opacity(0.04)],
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
