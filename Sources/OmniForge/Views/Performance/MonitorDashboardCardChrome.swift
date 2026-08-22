import SwiftUI

/// Shared card frame for monitor dashboard cards: Stats Light 规范纯白底无边框无投影卡片。
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
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(cardBackground)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onHover { hovering in
                guard isInteractive else { return }
                withAnimation(Theme.Animation.hover) {
                    isHovered = hovering
                }
            }
    }

    private var cardBackground: Color {
        if colorScheme == .dark {
            return Color.white.opacity(isHovered && isInteractive ? 0.10 : 0.08)
        }
        return isHovered && isInteractive ? Color(red: 0xFA/255.0, green: 0xFA/255.0, blue: 0xFC/255.0) : Theme.Stats.cardBackground
    }
}


