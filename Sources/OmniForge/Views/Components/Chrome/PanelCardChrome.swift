import SwiftUI

/// 控制中心通用卡片壳：底/边/阴影对齐系统监控总览卡，不绑定业务 accent 枚举。
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
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(cardBorder, lineWidth: 1)
            )
            .shadow(
                color: Color.black.opacity(shadowOpacity),
                radius: isHovered && isInteractive ? 10 : 6,
                x: 0,
                y: isHovered && isInteractive ? 4 : 2
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

extension View {
    /// 紧凑行卡：圆角 8/10、内边距由调用方控制（本修饰只做底/边/轻阴影）。
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
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(cardBorder, lineWidth: 1)
            )
            .shadow(
                color: Color.black.opacity(shadowOpacity),
                radius: isHovered && isInteractive ? 8 : 4,
                x: 0,
                y: isHovered && isInteractive ? 3 : 1
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
            return isHovered && isInteractive ? 0.18 : 0.10
        }
        return isHovered && isInteractive ? 0.06 : 0.03
    }
}

