import SwiftUI

/// Per-card accent colors for overview metric bars and icons.
enum MonitorCardAccent {
    /// Base emphasis color for a card (normal range).
    static func color(for id: MonitorCardID) -> Color {
        switch id {
        case .battery:
            return .green
        default:
            return .accentColor
        }
    }

    /// Bar fill for a card: accent in the normal range, orange/red at thresholds.
    static func barTint(for id: MonitorCardID, progress: Double) -> Color {
        let percent = MetricBar.clamp(progress) * 100
        if id == .battery {
            if percent <= 15 { return .red }
            if percent <= 35 { return .orange }
            return .green
        } else {
            if percent >= 85 { return .red }
            if percent >= 70 { return .orange }
            return .accentColor
        }
    }
}

/// Overview metric card: icon + title, primary/secondary value, optional bar, badge, live dot.
/// Whole card is a button when `action` is non-nil; issue state replaces primary and hides bar.
struct MonitorMetricCard: View {
    let title: String
    let systemImage: String
    let primaryText: String
    var secondaryText: String? = nil
    var progress: Double? = nil
    var accent: Color = .accentColor
    var badgeText: String? = nil
    var showsLiveDot: Bool = false
    var isRankable: Bool = false
    var issueText: String? = nil
    var fixedHeight: CGFloat? = nil
    let action: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    cardContent
                }
                .buttonStyle(.plain)
            } else {
                cardContent
            }
        }
        .onHover { hovering in
            guard isInteractive else { return }
            isHovered = hovering
        }
    }

    private var isInteractive: Bool { action != nil }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            valueBlock
            if let progress, issueText == nil {
                MetricBar(value: progress, warning: 101, critical: 101, tint: accent)
            }
        }
        .padding(12)
        .frame(
            maxWidth: .infinity,
            minHeight: fixedHeight,
            maxHeight: fixedHeight,
            alignment: .leading
        )
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(cardBorder, lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(shadowOpacity),
            radius: isHovered && isInteractive ? 10 : 6,
            x: 0,
            y: isHovered && isInteractive ? 4 : 2
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 18, height: 18)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if showsLiveDot {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(Text(badgeText ?? "Live"))
            }

            if let badgeText {
                Text(badgeText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.08))
                    )
                    .accessibilityHidden(showsLiveDot)
            }

            if isRankable {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var valueBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let issueText {
                Text(issueText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            } else {
                Text(primaryText)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if let secondaryText {
                    Text(secondaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var cardBackground: Color {
        if colorScheme == .dark {
            return Color.white.opacity(isHovered && isInteractive ? 0.10 : 0.06)
        }
        return Color.white.opacity(isHovered && isInteractive ? 0.75 : 0.55)
    }

    private var cardBorder: Color {
        if isHovered && isInteractive {
            return accent.opacity(colorScheme == .dark ? 0.45 : 0.35)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05)
    }

    private var shadowOpacity: Double {
        if colorScheme == .dark {
            return isHovered && isInteractive ? 0.20 : 0.12
        }
        return isHovered && isInteractive ? 0.08 : 0.04
    }
}
