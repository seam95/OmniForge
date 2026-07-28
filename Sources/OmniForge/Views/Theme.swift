import SwiftUI

public enum Theme {
    /// 统一强调色：macOS 系统 Blue Accent
    public static var accentColor: Color {
        Color.accentColor
    }

    /// 根据资源使用率百分比（0.0 ~ 1.0 或 0 ~ 100）返回语义状态色
    /// 正常(0~70%): 系统绿/蓝; 注意(70%~85%): 系统黄/琥珀色; 警戒(>85%): 系统红
    public static func statusColor(for fraction: Double, isInverse: Bool = false) -> Color {
        let value = fraction > 1.0 ? fraction / 100.0 : fraction
        if isInverse {
            if value < 0.15 { return .red }
            if value < 0.35 { return .orange }
            return .green
        } else {
            if value > 0.85 { return .red }
            if value > 0.70 { return .orange }
            return .green
        }
    }
}

/// 统一卡片 ViewModifier 修饰器：无硬描边，柔和毛玻璃 + 微内描边 + 漫反射阴影
public struct OmniCardModifier: ViewModifier {
    let isSelected: Bool
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    public init(isSelected: Bool = false, cornerRadius: CGFloat = 12) {
        self.isSelected = isSelected
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        isSelected
                        ? (colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.85))
                        : (colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.55))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.04),
                radius: isSelected ? 10 : 6,
                x: 0,
                y: isSelected ? 3 : 1.5
            )
    }
}

extension View {
    public func omniCardStyle(isSelected: Bool = false, cornerRadius: CGFloat = 12) -> some View {
        self.modifier(OmniCardModifier(isSelected: isSelected, cornerRadius: cornerRadius))
    }
}

public struct FooterButton: View {
    public let label: String
    public let systemImage: String
    public let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    public init(label: String, systemImage: String, action: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(label)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
