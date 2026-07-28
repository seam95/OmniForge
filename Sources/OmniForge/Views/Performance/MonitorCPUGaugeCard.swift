import SwiftUI

/// CPU dashboard card with a circular gauge, matching the reference status-card treatment.
struct MonitorCPUGaugeCard: View {
    let model: MonitorCardModel
    let height: CGFloat
    let action: () -> Void

    private var progress: Double {
        MetricBar.clamp(model.progress ?? 0)
    }

    private var accent: Color {
        MonitorCardAccent.barTint(for: .cpu, progress: progress)
    }

    var body: some View {
        Button(action: action) {
            MonitorDashboardCardChrome(accent: accent, height: height, isInteractive: true) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.07), lineWidth: 8)

                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            accent,
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))

                    VStack(spacing: 2) {
                        if let issueText = model.issueText {
                            Text(issueText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        } else {
                            Text(model.primaryText)
                                .font(.title2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(accent)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)

                            Text(model.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .buttonStyle(.plain)
    }
}
