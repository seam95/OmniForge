import SwiftUI

/// 网络卡 — 左列速率（绿下行 / 红上行粗字）+ 右侧双色镜像趋势图 + 灰色累计 caption。
struct MonitorNetworkCard: View {
    let model: MonitorCardModel
    let accent: Color
    let height: CGFloat
    let action: () -> Void

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
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    } else {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                rateRow(downText, color: .primary, indicatorColor: .green)
                                rateRow(upText, color: .primary, indicatorColor: MonitorCardAccent.networkUpload)

                                if let caption = model.secondaryText {
                                    Text(caption)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
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
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(indicatorColor)
                .frame(width: 8, height: 8)

            Text(text ?? "--")
                .font(.system(size: 15.5, weight: .bold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(accent)
                .frame(width: 8.5, height: 8.5)

            Text(model.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let badgeText = model.badgeText {
                Text(badgeText)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(isHovered ? 1 : 0)
        }
    }
}
