import SwiftUI

/// Combined power card for overview: battery status plus system energy usage in one framed card.
///
/// Battery and energy share the same `power`-section issue source. When both carry issue text
/// the card shows it only once (in the battery section) to avoid duplication.
struct MonitorPowerMetricCard: View {
    let battery: MonitorCardModel
    let energy: MonitorCardModel
    let height: CGFloat
    let onSelectEnergy: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isEnergyHovered = false

    /// Energy section suppresses its own issue text when battery already shows the
    /// same power-section issue.
    private var effectiveEnergy: MonitorCardModel {
        guard battery.issueText != nil, energy.issueText != nil else { return energy }
        var copy = energy
        copy.issueText = nil
        return copy
    }

    var body: some View {
        HStack(spacing: 10) {
            batterySection
                .frame(maxWidth: .infinity, alignment: .leading)
            divider
            energyButton
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
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
            radius: isEnergyHovered ? 10 : 6,
            x: 0,
            y: isEnergyHovered ? 4 : 2
        )
    }

    private var batterySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            metricHeader(
                model: battery,
                accent: batteryAccent,
                showsChevron: false
            )
            metricValue(model: battery)
            if let progress = battery.progress, battery.issueText == nil {
                MetricBar(value: progress, warning: 101, critical: 101, tint: batteryAccent)
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
            .frame(width: 1)
    }

    private var energyButton: some View {
        Button(action: onSelectEnergy) {
            VStack(alignment: .leading, spacing: 8) {
                metricHeader(
                    model: effectiveEnergy,
                    accent: energyAccent,
                    showsChevron: true
                )
                metricValue(model: effectiveEnergy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isEnergyHovered = hovering
        }
    }

    private func metricHeader(
        model: MonitorCardModel,
        accent: Color,
        showsChevron: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: model.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 18, height: 18)

            Text(model.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func metricValue(model: MonitorCardModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let issueText = model.issueText {
                Text(issueText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            } else {
                Text(model.primaryText)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if let secondaryText = model.secondaryText {
                    Text(secondaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var batteryAccent: Color {
        if let progress = battery.progress {
            return MonitorCardAccent.barTint(for: .battery, progress: progress)
        }
        return MonitorCardAccent.color(for: .battery)
    }

    private var energyAccent: Color {
        MonitorCardAccent.color(for: .energy)
    }

    private var cardBackground: Color {
        if colorScheme == .dark {
            return Color.white.opacity(isEnergyHovered ? 0.10 : 0.06)
        }
        return Color.white.opacity(isEnergyHovered ? 0.75 : 0.55)
    }

    private var cardBorder: Color {
        if isEnergyHovered {
            return energyAccent.opacity(colorScheme == .dark ? 0.45 : 0.35)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05)
    }

    private var shadowOpacity: Double {
        if colorScheme == .dark {
            return isEnergyHovered ? 0.20 : 0.12
        }
        return isEnergyHovered ? 0.08 : 0.04
    }
}
