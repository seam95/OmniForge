import AppKit
import SwiftUI

/// Shared visual tokens for the shelf surfaces — Control Center–adjacent, not HUD.
enum ShelfChrome {
    static let panelWidth: CGFloat = 300
    static let tileAreaHeight: CGFloat = 196
    static let panelCorner: CGFloat = 14
    static let pillCorner: CGFloat = 20
    static let controlSize: CGFloat = 26
    static let tileSize = CGSize(width: 76, height: 88)

    static func panelBackground(colorScheme: ColorScheme) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: panelCorner, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: panelCorner, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor)
                    .opacity(colorScheme == .dark ? 0.28 : 0.18))
            // Subtle top highlight like system popovers
            RoundedRectangle(cornerRadius: panelCorner, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.14 : 0.55),
                            Color.white.opacity(colorScheme == .dark ? 0.04 : 0.12)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
        }
    }

    static func pillBackground(colorScheme: ColorScheme) -> some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
            Capsule(style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor)
                    .opacity(colorScheme == .dark ? 0.32 : 0.22))
            Capsule(style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.08),
                    lineWidth: 0.6
                )
        }
    }

    }

/// Compact circular control used in shelf headers — system-adjacent, not stroked HUD rings.
struct ShelfHeaderButton: View {
    let systemImage: String
    var isActive: Bool = false
    var isDestructive: Bool = false
    let help: String
    let action: () -> Void

    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: ShelfChrome.controlSize, height: ShelfChrome.controlSize)
                .foregroundStyle(foreground)
                .background(background, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.12), value: isActive)
    }

    private var foreground: Color {
        if isDestructive {
            return hovered ? Color.red.opacity(0.9) : Color.secondary
        }
        if isActive {
            return Color.accentColor
        }
        return hovered ? Color.primary.opacity(0.85) : Color.secondary
    }

    private var background: Color {
        if isDestructive {
            return Color.red.opacity(hovered ? 0.16 : 0.0)
        }
        if isActive {
            return Color.accentColor.opacity(hovered ? 0.22 : 0.14)
        }
        return Color.primary.opacity(hovered ? (colorScheme == .dark ? 0.14 : 0.08) : 0.0)
    }
}
