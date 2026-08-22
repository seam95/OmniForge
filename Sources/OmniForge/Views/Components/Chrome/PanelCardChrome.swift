import SwiftUI

/// 控制中心通用卡片壳：Stats 浅色版无描边无投影，靠白/浅灰对比分层。
struct PanelCardChrome<Content: View>: View {
    var cornerRadius: CGFloat = Theme.Radius.card
    var padding: CGFloat = Theme.Spacing.md
    var isInteractive: Bool = false
    var accent: Color = Theme.accentColor
    let content: Content

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    init(
        cornerRadius: CGFloat = Theme.Radius.card,
        padding: CGFloat = Theme.Spacing.md,
        isInteractive: Bool = false,
        accent: Color = Theme.accentColor,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.isInteractive = isInteractive
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(cardBackground)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
        return isHovered && isInteractive ? Color(red: 0xFA/255.0, green: 0xFA/255.0, blue: 0xFC/255.0) : Theme.Stats.cardBackground
    }
}

extension View {
    /// 紧凑行卡：圆角 8/10、内边距由调用方控制（纯色对比底分层）。
    func panelRowCard(
        cornerRadius: CGFloat = Theme.Radius.row,
        isInteractive: Bool = false,
        accent: Color = Theme.accentColor
    ) -> some View {
        modifier(
            PanelRowCardModifier(
                cornerRadius: cornerRadius,
                isInteractive: isInteractive,
                accent: accent
            )
        )
    }
}

private struct PanelRowCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let isInteractive: Bool
    let accent: Color

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(cardBackground)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
        return isHovered && isInteractive ? Color(red: 0xFA/255.0, green: 0xFA/255.0, blue: 0xFC/255.0) : Theme.Stats.cardBackground
    }
}


