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
                VStack(alignment: .leading, spacing: 4) {
                    header

                    if let issueText = model.issueText {
                        Text(issueText)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    } else {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 6) {
                                rateText(downText, color: .green)
                                rateText(upText, color: MonitorCardAccent.networkUpload)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            DualSparklineView(
                                downValues: model.trend ?? [],
                                upValues: model.secondaryTrend ?? []
                            )
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: .infinity)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if let caption = model.secondaryText {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func rateText(_ text: String?, color: Color) -> some View {
        Text(text ?? "--")
            .font(.headline.weight(.semibold).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(accent)
                .frame(width: 8, height: 8)

            Text(model.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if model.showsLiveDot {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(Text(model.badgeText ?? "Live"))
            }

            if let badgeText = model.badgeText {
                Text(badgeText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .opacity(isHovered ? 1 : 0)
        }
    }
}
