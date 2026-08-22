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
    /// Stats Light 设计规范色值与字阶
    public enum Stats {
        public static let panelBackground = Color(red: 0xF2/255.0, green: 0xF2/255.0, blue: 0xF5/255.0)
        public static let cardBackground = Color.white
        public static let cardInset = Color(red: 0xEE/255.0, green: 0xEE/255.0, blue: 0xEF/255.0)
        public static let text1 = Color(red: 0x1C/255.0, green: 0x1C/255.0, blue: 0x1E/255.0)
        public static let text2 = Color(red: 0x6E/255.0, green: 0x6E/255.0, blue: 0x73/255.0)
        public static let text3 = Color(red: 0xAD/255.0, green: 0xAD/255.0, blue: 0xB2/255.0)
        public static let separator = Color(red: 0xE5/255.0, green: 0xE5/255.0, blue: 0xEA/255.0)

        // 模块色
        public static let cpu = Color(red: 0x0A/255.0, green: 0x84/255.0, blue: 0xFF/255.0)
        public static let ram = Color(red: 0xFF/255.0, green: 0x9F/255.0, blue: 0x0A/255.0)
        public static let gpu = Color(red: 0xAF/255.0, green: 0x52/255.0, blue: 0xDE/255.0)
        public static let down = Color(red: 0x33/255.0, green: 0xC7/255.0, blue: 0x59/255.0)
        public static let battery = Color(red: 0x33/255.0, green: 0xC7/255.0, blue: 0x59/255.0)
        public static let up = Color(red: 0xFF/255.0, green: 0x45/255.0, blue: 0x3A/255.0)
        public static let statusNormal = Color(red: 0x1F/255.0, green: 0xA9/255.0, blue: 0x4A/255.0)

        // 5 级字体
        public static let font24Bold = Font.system(size: 24, weight: .bold)
        public static let font13SemiBold = Font.system(size: 13, weight: .semibold)
        public static let font12Medium = Font.system(size: 12, weight: .medium)
        public static let font11Regular = Font.system(size: 11, weight: .regular)
        public static let font10Regular = Font.system(size: 10, weight: .regular)
    }
}

/// 统一卡片 ViewModifier 修饰器：Stats 浅色版无描边无投影，靠白/浅灰对比分层
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
                return Color.white
            }
            return isHovered && isInteractive ? Color(red: 0xFA/255.0, green: 0xFA/255.0, blue: 0xFC/255.0) : Color.white
        }
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
    /// nil 保持现状（secondary 灰字）；非 nil 覆盖整组前景色。
    public var tint: Color? = nil
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    public init(label: String, systemImage: String? = nil, tint: Color? = nil, action: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.tint = tint
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
                    .font(Theme.Stats.font12Medium)
            }
            .foregroundStyle(tint ?? (colorScheme == .light ? Theme.Stats.text2 : Color.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.05) : Color.clear)
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

/// 纯图标小按钮：悬浮圆角底，配合 `FooterButton` 的视觉语言；`help` 提供悬停提示。
public struct IconButton: View {
    public let systemImage: String
    public let action: () -> Void
    /// nil 保持现状（secondary 灰字）；非 nil 覆盖前景色。
    public var tint: Color? = nil
    public var help: String? = nil
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    public init(
        systemImage: String,
        tint: Color? = nil,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.tint = tint
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint ?? (colorScheme == .light ? Theme.Stats.text2 : Color.secondary))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.05) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Theme.Animation.hover) {
                isHovered = hovering
            }
        }
        .help(help ?? "")
    }
}

