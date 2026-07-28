import SwiftUI

/// Memory dashboard card styled after the reference: title, primary usage, total hint, and status chips.
struct MonitorMemoryDashboardCard: View {
    let model: MonitorCardModel
    let height: CGFloat
    let action: () -> Void

    private var accent: Color {
        if let progress = model.progress {
            return MonitorCardAccent.barTint(for: .memory, progress: progress)
        }
        return MonitorCardAccent.color(for: .memory)
    }

    var body: some View {
        Button(action: action) {
            MonitorDashboardCardChrome(accent: accent, height: height, isInteractive: true) {
                VStack(alignment: .leading, spacing: 9) {
                    header
                    valueLine
                    if let progress = model.progress, model.issueText == nil {
                        MetricBar(value: progress, warning: 101, critical: 101, tint: accent)
                    }
                    statusChips
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 18, height: 18)

            Text(model.title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var valueLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let issueText = model.issueText {
                Text(issueText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Text(model.primaryText)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
    }

    private var statusChips: some View {
        HStack(spacing: 8) {
            chip(value: model.secondaryText ?? "--")
            chip(value: model.progress.map { "\(Int(MetricBar.clamp($0) * 100))%" } ?? "--")
        }
    }

    private func chip(value: String) -> some View {
        Text(value)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
    }
}
