import SwiftUI

/// 磁盘卡 — 标题行（蓝点 + "磁盘" + 右上"已用"灰字 + 悬浮 chevron）+ 两个并排灰框（读取/写入）。
struct MonitorDiskMetricCard: View {
    let model: MonitorCardModel
    let accent: Color
    let height: CGFloat
    let action: () -> Void

    @State private var isHovered = false

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
                        HStack(spacing: 10) {
                            ForEach(model.chipTexts, id: \.self) { chip in
                                Text(chip)
                                    .font(.title3.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                                            .fill(Color.primary.opacity(0.04))
                                    )
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
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

            if let badgeText = model.badgeText {
                Text(badgeText)
                    .font(.caption.weight(.semibold).monospacedDigit())
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
