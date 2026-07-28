import SwiftUI

/// Compact full-width disk card: read/write rates are primary; capacity is supporting context.
struct MonitorDiskMetricCard: View {
    let model: MonitorCardModel
    let strings: Strings
    let height: CGFloat
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                header
                valueRow
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
                radius: isHovered ? 10 : 6,
                x: 0,
                y: isHovered ? 4 : 2
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 18, height: 18)

            Text(model.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 6)

            Text(model.primaryText)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var valueRow: some View {
        HStack(spacing: 10) {
            ForEach(rateParts, id: \.label) { part in
                VStack(alignment: .leading, spacing: 2) {
                    Text(part.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(part.value)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04))
                )
            }
        }
    }

    private var rateParts: [DiskRatePart] {
        let secondary = model.secondaryText ?? "↓ -- • ↑ --"
        let pieces = secondary
            .replacingOccurrences(of: "•", with: "|")
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let read = pieces.first?.replacingOccurrences(of: "↓", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let write = pieces.dropFirst().first?.replacingOccurrences(of: "↑", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            DiskRatePart(label: strings.monitorMetricRead, value: "↓ \(nonEmpty(read) ?? "--")"),
            DiskRatePart(label: strings.monitorMetricWrite, value: "↑ \(nonEmpty(write) ?? "--")")
        ]
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private var accent: Color {
        MonitorCardAccent.color(for: .disk)
    }

    private var cardBackground: Color {
        if colorScheme == .dark {
            return Color.white.opacity(isHovered ? 0.10 : 0.06)
        }
        return Color.white.opacity(isHovered ? 0.75 : 0.55)
    }

    private var cardBorder: Color {
        if isHovered {
            return accent.opacity(colorScheme == .dark ? 0.45 : 0.35)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05)
    }

    private var shadowOpacity: Double {
        if colorScheme == .dark {
            return isHovered ? 0.20 : 0.12
        }
        return isHovered ? 0.08 : 0.04
    }
}

private struct DiskRatePart {
    let label: String
    let value: String
}
