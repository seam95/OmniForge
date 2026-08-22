import SwiftUI

struct MonitorDiskMetricCard: View {
    let model: MonitorCardModel
    let accent: Color
    let height: CGFloat
    let action: () -> Void
    var strings: Strings = .en

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            MonitorDashboardCardChrome(accent: accent, height: height, isInteractive: true) {
                VStack(alignment: .leading, spacing: 8) {
                    header

                    if let issueText = model.issueText {
                        Text(issueText)
                            .font(Theme.Stats.font13SemiBold)
                            .foregroundStyle(Theme.Stats.up)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    } else {
                        HStack(spacing: 10) {
                            diskBox(
                                label: strings.monitorMetricRead,
                                value: model.chipTexts.indices.contains(0) ? model.chipTexts[0] : "--"
                            )
                            diskBox(
                                label: strings.monitorMetricWrite,
                                value: model.chipTexts.indices.contains(1) ? model.chipTexts[1] : "--"
                            )
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

    private func diskBox(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
            Text(value)
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.08))
        )
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
