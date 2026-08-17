import SwiftUI

/// Shared card frame for monitor dashboard cards.
struct MonitorDashboardCardChrome<Content: View>: View {
    let accent: Color
    let height: CGFloat
    var isInteractive = false
    let content: Content

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    init(
        accent: Color,
        height: CGFloat,
        isInteractive: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.accent = accent
        self.height = height
        self.isInteractive = isInteractive
        self.content = content()
    }

    var body: some View {
        content
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(cardBorder, lineWidth: 1)
            )
            .shadow(
                color: Color.black.opacity(shadowOpacity),
                radius: isHovered && isInteractive ? 10 : 6,
                x: 0,
                y: isHovered && isInteractive ? 4 : 2
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .onHover { hovering in
                guard isInteractive else { return }
                withAnimation(Theme.Animation.hover) {
                    isHovered = hovering
                }
            }
    }

    private var cardBackground: Color {
        if colorScheme == .dark {
            return Color.white.opacity(isHovered && isInteractive ? 0.10 : 0.06)
        }
        return Color.white.opacity(isHovered && isInteractive ? 0.78 : 0.58)
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

