import SwiftUI

/// 单序列折线 — 用于 CPU/GPU/内存百分比趋势（domain 0...1）与网络速率趋势。
///
/// 不加隐式动画，随 snapshot 同频直接重绘；空/单点/恒定值由 `SparklineNormalizer` 兜底。
/// `fillHeight > 0` 时线下叠面积渐变；`endDotRadius > 0` 时在右端点画圆点标记最新值。
/// `hoverFormatter` 非 nil 时启用悬浮取值：指示线 + 选中点 + 数值气泡。
struct SparklineView: View {
    let values: [Double]
    let color: Color
    var domain: ClosedRange<Double> = 0...1
    var lineWidth: CGFloat = 1.5
    var fillHeight: CGFloat = 0.18
    var endDotRadius: CGFloat = 0
    /// 非 nil 启用悬浮取值：把悬停采样点的原始值转成气泡文本
    var hoverFormatter: ((Double) -> String)? = nil
    /// 各采样点时刻（与 values 逐点配对）：非 nil 时气泡在数值下补一行 HH:mm:ss
    var hoverTimestamps: [Date]? = nil

    @State private var hoveredIndex: Int?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let points = resolvedPoints(size: proxy.size)

            ZStack {
                if points.count >= 2 {
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
                if let index = hoveredIndex,
                   points.indices.contains(index) {
                    let tip = points[index]
                    hoverIndicator(point: tip, height: proxy.size.height)
                    hoverBubble(atX: tip.x, height: proxy.size.height, width: proxy.size.width)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                updateHover(phase: phase, width: proxy.size.width)
            }
        }
    }

    // MARK: - 悬浮取值

    private func updateHover(phase: HoverPhase, width: CGFloat) {
        guard hoverFormatter != nil else { return }
        switch phase {
        case .active(let location):
            hoveredIndex = SparklineHoverLocator.index(
                atX: location.x, width: width, count: values.count
            )
        case .ended:
            hoveredIndex = nil
        }
    }

    // MARK: - 绘制

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

    // MARK: - 悬浮层

    /// 悬停 x 处的全高指示线 + 折线上的选中点。
    private func hoverIndicator(point: CGPoint, height: CGFloat) -> some View {
        SparklineHoverIndicator(point: point, height: height, color: color)
    }

    /// 数值气泡：锚在选中点正下方（x 跟随、y 固定折线底边外侧），悬浮于折线区域
    /// 之外避免遮挡走势本体；指示线全高贯穿，气泡挂在其脚下保持视觉关联。
    private func hoverBubble(atX x: CGFloat, height: CGFloat, width: CGFloat) -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .position(x: x, y: height)
            .overlay(alignment: SparklineHoverLocator.bubbleAlignment(atX: x, width: width)) {
                if let formatter = hoverFormatter,
                   let index = hoveredIndex,
                   values.indices.contains(index) {
                    SparklineBubbleShell(colorScheme: colorScheme) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(formatter(values[index]))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                            if let time = hoverTimestamps?[index] {
                                Text(SparklineTimeText.time(time))
                                    .font(.system(size: 10, weight: .regular).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .allowsHitTesting(false)
    }
}

/// 折线悬浮气泡壳 — 胶囊底 + 发丝描边 + 微阴影，内容自定义（单值文本 / 双值行）。
struct SparklineBubbleShell<Content: View>: View {
    let colorScheme: ColorScheme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(colorScheme == .light ? Color.white : Color(white: 0.24))
                    .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        colorScheme == .light ? Theme.Stats.separator : Color.white.opacity(0.14),
                        lineWidth: 1
                    )
            )
            .fixedSize()
    }
}

/// 折线悬浮指示层 — 全高竖线 + 描边选中点，单线与双线共用。
struct SparklineHoverIndicator: View {
    let point: CGPoint
    let height: CGFloat
    let color: Color

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 1, height: height)
                .position(x: point.x, y: height / 2)

            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                .frame(width: 7, height: 7)
                .position(point)
        }
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

/// 悬浮取值几何工具 — 纯函数，独立可测。
enum SparklineHoverLocator {
    /// 悬停 x → 最近采样点下标；不足两点（无法定位趋势）返回 nil。
    static func index(atX x: CGFloat, width: CGFloat, count: Int) -> Int? {
        guard count >= 2, width > 0 else { return nil }
        let clamped = min(max(x, 0), width)
        let ratio = clamped / width
        return min(Int((ratio * CGFloat(count - 1)).rounded()), count - 1)
    }

    /// 气泡对齐三档（锚点下方悬挂）：左 1/3 左贴、右 1/3 右贴、中间居中，避免气泡出界。
    static func bubbleAlignment(atX x: CGFloat, width: CGFloat) -> Alignment {
        if x < width / 3 { return .topLeading }
        if x > width * 2 / 3 { return .topTrailing }
        return .top
    }
}

/// 悬浮气泡时间文本 — HH:mm:ss 本地时区（秒级粒度可区分同一分钟内的多个采样点）。
/// formatter 创建开销大，静态缓存；DateFormatter 非线程安全，仅主线程 UI 渲染调用。
enum SparklineTimeText {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func time(_ date: Date) -> String {
        formatter.string(from: date)
    }
}
