import SwiftUI

// MARK: - 实用工具共享视觉组件
//
// 卸载器与清理共用的一套小组件：品牌徽章、比例条、完成态。
// 目标是让两个工具页读起来像一个家族：数字是主角，明细退一步。

enum UtilityKit {
    static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// 品牌徽章：tint 低透明度圆角方块 + tint 色 SF Symbol，与实用工具列表行的图标语言一致。
struct UtilityGlyphTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 44
    var symbolSize: CGFloat? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(tint.opacity(0.14))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: symbolSize ?? size * 0.44, weight: .semibold))
                    .foregroundStyle(tint)
            )
    }
}

/// 分段比例条：把总量按段画成一根圆角胶囊，让人一眼看出构成占比。
/// 占比过小的段以最小宽度兜底，避免消失。
struct UtilityProportionBar: View {
    struct Segment: Identifiable {
        let id = UUID()
        let color: Color
        let value: Double
    }

    let segments: [Segment]
    var height: CGFloat = 8

    /// 小于该比例仍可见的最小段宽。
    private static let minFraction: CGFloat = 0.02

    var body: some View {
        let total = segments.reduce(0.0) { $0 + max(0, $1.value) }
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(visibleSegments(total: total)) { segment in
                    RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                        .fill(segment.color)
                        .frame(width: width(for: segment, total: total, in: proxy.size.width))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func visibleSegments(total: Double) -> [Segment] {
        segments.filter { total > 0 && $0.value > 0 }
    }

    private func width(for segment: Segment, total: Double, in available: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let fraction = CGFloat(segment.value / total)
        return max(Self.minFraction, fraction) * available
    }
}

/// 工具完成态共享视图：大对勾 + 大号释放数字 + 折叠明细 + 操作按钮。
/// 成功明细默认折叠成一行摘要（噪音），失败明细始终展开（需要处理）。
struct UtilityDoneView<Buttons: View>: View {
    let strings: Strings
    let freed: Int64
    let failedCount: Int
    /// 附加说明（如清理的「可从废纸篓恢复」），nil 则不显示。
    var note: String? = nil
    /// 部分失败时的警告文案。
    var warning: String? = nil
    var succeeded: [(name: String, path: String)] = []
    var failures: [(name: String, path: String, message: String)] = []
    var layout: UtilityContentLayout = .settings
    @ViewBuilder var buttons: Buttons

    @State private var detailsExpanded = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: layout == .compact ? 42 : 54))
                    .foregroundStyle(failedCount == 0 ? Theme.Stats.statusNormal : Theme.Stats.ram)
                    .symbolEffect(.bounce, value: freed)

                Text(UtilityKit.byteString(freed))
                    .font(.system(size: layout == .compact ? 26 : 32, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.Stats.statusNormal)
                    .padding(.top, -6)

                Text(strings.toolFreedLabel)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                    .padding(.top, -8)

                if failedCount > 0, let warning {
                    Text(warning)
                        .font(Theme.Stats.font10Regular)
                        .foregroundStyle(Theme.Stats.ram)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }

                if let note {
                    Text(note)
                        .font(Theme.Stats.font10Regular)
                        .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }

                detailsCard

                HStack(spacing: 8) { buttons }
                    .controlSize(.regular)
                    .font(Theme.Stats.font12Medium)
                    .padding(.top, 4)
            }
            .padding(layout.horizontalPadding)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: layout == .compact ? 320 : 0)
    }

    @ViewBuilder
    private var detailsCard: some View {
        if !succeeded.isEmpty || !failures.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !succeeded.isEmpty {
                    succeededDisclosure
                }
                if !failures.isEmpty {
                    sectionHeader(strings.toolFailed, count: failures.count, color: Theme.Stats.ram)
                    ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                        row(name: failure.name, path: failure.path, message: failure.message)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // inset 数据行语言：浅灰底圆角块（原 utilityInsetBackground 内联）
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Theme.Stats.cardInset)
            )
        }
    }

    private var succeededDisclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(Theme.Animation.snappy) { detailsExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(Theme.Stats.statusNormal).frame(width: 7, height: 7)
                    Text(String(format: strings.toolSucceededSummaryFormat, succeeded.count))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                    Spacer()
                    Text(detailsExpanded ? strings.toolHideDetails : strings.toolShowDetails)
                        .font(.caption2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(detailsExpanded ? 90 : 0))
                }
                .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if detailsExpanded {
                ForEach(Array(succeeded.enumerated()), id: \.offset) { _, item in
                    row(name: item.name, path: item.path, message: nil)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption.weight(.semibold))
            Text("\(count)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func row(name: String, path: String, message: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            if let message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
