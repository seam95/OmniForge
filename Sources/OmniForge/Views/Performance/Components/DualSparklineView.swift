import SwiftUI

/// 网络双序列走势图 — 下行绿线与上行红线在同一坐标域内全幅绘制。
///
/// 共享 domain `0...max(up, down, 1)`：上行通常远小于下行，自然沉在下方区域。
/// 上行线降低不透明度以区分主次；下行右端圆点标记最新值。
/// `hoverFormatter` 非 nil 时启用悬浮取值：指示线 + 下行选中点 + 下/上双值气泡。
struct DualSparklineView: View {
    let downValues: [Double]
    let upValues: [Double]
    var lineWidth: CGFloat = 1.4
    /// 非 nil 启用悬浮取值；下行/上行共用同一格式化器（网络场景均为速率）。
    var hoverFormatter: ((Double) -> String)? = nil
    /// 下行序列各采样点时刻（悬浮 index 按 downValues 定位）：非 nil 时气泡补一行 HH:mm:ss
    var hoverTimestamps: [Date]? = nil

    @State private var hoveredIndex: Int?

    @Environment(\.colorScheme) private var colorScheme

    private var domain: ClosedRange<Double> {
        let peak = max(downValues.max() ?? 0, upValues.max() ?? 0)
        return 0...max(peak, 1)
    }

    var body: some View {
        GeometryReader { proxy in
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

                if let index = hoveredIndex, downValues.indices.contains(index) {
                    let point = CGPoint(x: hoverX(index: index, width: proxy.size.width),
                                        y: downY(index: index, height: proxy.size.height))
                    SparklineHoverIndicator(point: point, height: proxy.size.height, color: Theme.Stats.down)
                    hoverBubble(atX: point.x, height: proxy.size.height, width: proxy.size.width)
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
                atX: location.x, width: width, count: downValues.count
            )
        case .ended:
            hoveredIndex = nil
        }
    }

    /// 悬停 x 与共享 domain 下行线的 y。
    private func hoverX(index: Int, width: CGFloat) -> CGFloat {
        guard downValues.count > 1, width > 0 else { return 0 }
        return width * CGFloat(index) / CGFloat(downValues.count - 1)
    }

    private func downY(index: Int, height: CGFloat) -> CGFloat {
        let normalized = SparklineNormalizer.normalize(values: downValues, domain: domain)
        guard normalized.indices.contains(index) else { return height / 2 }
        return height * (1 - normalized[index])
    }

    /// 数值气泡：锚在选中点正下方（x 跟随、y 固定折线底边外侧），不遮挡双线走势本体。
    private func hoverBubble(atX x: CGFloat, height: CGFloat, width: CGFloat) -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .position(x: x, y: height)
            .overlay(alignment: SparklineHoverLocator.bubbleAlignment(atX: x, width: width)) {
                if let formatter = hoverFormatter,
                   let index = hoveredIndex,
                   downValues.indices.contains(index) {
                    SparklineBubbleShell(colorScheme: colorScheme) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                HStack(spacing: 2) {
                                    Image(systemName: "arrow.down")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Theme.Stats.down)
                                    Text(formatter(downValues[index]))
                                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                                }
                                HStack(spacing: 2) {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Theme.Stats.up)
                                    Text(upValues.indices.contains(index)
                                        ? formatter(upValues[index]) : "--")
                                        .font(.system(size: 11, weight: .regular).monospacedDigit())
                                }
                            }
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
