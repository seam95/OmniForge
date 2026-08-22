import SwiftUI

/// 网络卡 — 左列速率（绿下行 / 红上行粗字）+ 右侧双色镜像趋势图 + 灰色累计 caption。
struct MonitorNetworkCard: View {
    let model: MonitorCardModel
    let accent: Color
    let height: CGFloat
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var downText: String? {
        model.chipTexts.indices.contains(0) ? model.chipTexts[0] : nil
    }

    private var upText: String? {
        model.chipTexts.indices.contains(1) ? model.chipTexts[1] : nil
    }

    var body: some View {
        Button(action: action) {
            MonitorDashboardCardChrome(accent: accent, height: height, isInteractive: true) {
                VStack(alignment: .leading, spacing: 6) {
                    header

                    if let issueText = model.issueText {
                        Text(issueText)
                            .font(Theme.Stats.font13SemiBold)
                            .foregroundStyle(Theme.Stats.up)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    } else {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                rateRow(downText, color: colorScheme == .light ? Theme.Stats.text1 : Color.primary, indicatorColor: Theme.Stats.down)
                                rateRow(upText, color: colorScheme == .light ? Theme.Stats.text1 : Color.primary, indicatorColor: Theme.Stats.up)

                                if let caption = model.secondaryText {
                                    Text(caption)
                                        .font(Theme.Stats.font10Regular)
                                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                        .padding(.top, 2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            DualSparklineView(
                                downValues: model.trend ?? [],
                                upValues: model.secondaryTrend ?? []
                            )
                            .frame(width: 135)
                            .frame(maxHeight: .infinity)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func rateRow(_ text: String?, color: Color, indicatorColor: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(indicatorColor)
                .frame(width: 8, height: 8)

            Text(text ?? "--")
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accent)
                .frame(width: 8, height: 8)

            Text(model.title)
                .font(Theme.Stats.font13SemiBold)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text2 : Color.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let badgeText = model.badgeText {
                Text(badgeText)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                    .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                .opacity(isHovered ? 1 : 0)
        }
    }
}
