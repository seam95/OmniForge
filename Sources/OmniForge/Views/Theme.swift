import SwiftUI

public enum Theme {
    /// 统一强调色：macOS 系统 Blue Accent
    public static var accentColor: Color {
        Color.accentColor
    }

    /// 圆角梯度规范
    public enum Radius {
        /// 微型控件、状态徽章、进度条圆角 (6pt)
        public static let micro: CGFloat = 6
        /// 列表行、输入框、按钮 (8pt)
        public static let row: CGFloat = 8
        /// 标准卡片、监控卡片、分组块 (12pt)
        public static let card: CGFloat = 12
        /// 弹窗主容器、Sheet 外壳 (16pt)
        public static let container: CGFloat = 16
    }

    /// 间距梯度规范
    public enum Spacing {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 6
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 20
    }

    /// 微动效规范
    public enum Animation {
        public static let hover = SwiftUI.Animation.easeInOut(duration: 0.15)
        public static let snappy = SwiftUI.Animation.snappy(duration: 0.20)
        public static let spring = SwiftUI.Animation.spring(response: 0.30, dampingFraction: 0.75)
    }

    /// 根据资源使用率百分比（0.0 ~ 1.0 或 0 ~ 100）返回语义状态色
    /// 正常(0~70%): 系统绿; 注意(70%~85%): 系统黄/橙; 警戒(>85%): 系统红
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

    /// 状态背景色（低不透明度填充）
    public static func statusBackground(for fraction: Double, isInverse: Bool = false) -> Color {
        statusColor(for: fraction, isInverse: isInverse).opacity(0.14)
    }
}

/// 统一卡片 ViewModifier 修饰器：无硬描边，柔和毛玻璃 + 微内描边 + 漫反射阴影
public struct OmniCardModifier: ViewModifier {
    let isSelected: Bool
    let cornerRadius: CGFloat
    let isInteractive: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    public init(isSelected: Bool = false, cornerRadius: CGFloat = Theme.Radius.card, isInteractive: Bool = false) {
        self.isSelected = isSelected
        self.cornerRadius = cornerRadius
        self.isInteractive = isInteractive
    }

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        strokeBorderColor,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .shadow(
                color: Color.black.opacity(shadowOpacity),
                radius: (isSelected || (isHovered && isInteractive)) ? 10 : 6,
                x: 0,
                y: (isSelected || (isHovered && isInteractive)) ? 3.5 : 1.5
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering in
                guard isInteractive else { return }
                withAnimation(Theme.Animation.hover) {
                    isHovered = hovering
                }
            }
    }

    private var backgroundFill: Color {
        if colorScheme == .dark {
            if isSelected {
                return Color.white.opacity(0.14)
            }
            return Color.white.opacity(isHovered && isInteractive ? 0.10 : 0.06)
        } else {
            if isSelected {
                return Color.white.opacity(0.90)
            }
            return Color.white.opacity(isHovered && isInteractive ? 0.78 : 0.60)
        }
    }

    private var strokeBorderColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.60)
        }
        if isHovered && isInteractive {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.40 : 0.30)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05)
    }

    private var shadowOpacity: Double {
        if colorScheme == .dark {
            return (isSelected || (isHovered && isInteractive)) ? 0.22 : 0.12
        }
        return (isSelected || (isHovered && isInteractive)) ? 0.08 : 0.04
    }
}

extension View {
    public func omniCardStyle(
        isSelected: Bool = false,
        cornerRadius: CGFloat = Theme.Radius.card,
        isInteractive: Bool = false
    ) -> some View {
        self.modifier(OmniCardModifier(isSelected: isSelected, cornerRadius: cornerRadius, isInteractive: isInteractive))
    }
}

public struct FooterButton: View {
    public let label: String
    public let systemImage: String?
    public let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    public init(label: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage, !systemImage.isEmpty {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Theme.Animation.hover) {
                isHovered = hovering
            }
        }
    }
}

