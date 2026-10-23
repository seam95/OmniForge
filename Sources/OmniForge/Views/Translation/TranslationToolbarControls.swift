import SwiftUI

// MARK: - 浮窗工具条与卡片微控件

/// 胶囊菜单项：`value` 参与选择比较，`title` 为本地化显示名。
struct TranslationPickOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
}

/// 语言选择胶囊按钮：自绘圆角胶囊 + 系统 NSPopover 菜单列表。
///
/// 不用 `Menu` / `Picker(.menu)` 的原因：系统菜单按钮自带固定底色与边距，
/// 难以做成对称等宽语言栏；popover 列表由本视图排版，仍保留系统圆角阴影与 Esc 关闭。
struct TranslationPickMenu<Value: Hashable>: View {
    let options: [TranslationPickOption<Value>]
    /// 当前选中项的显示文本（由调用方按本地化及自动识别结果解析）。
    let title: String
    /// 次级补充标签（如「自动检测」已识别出的具体语种），nil 时只显示主标题。
    var badge: String? = nil
    @Binding var selection: Value
    let help: String
    var fillsAvailableWidth: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPresented = false
    @State private var isHovered = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)

                if let badge, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(TranslationPresentation.tint)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(TranslationPresentation.tint.opacity(colorScheme == .dark ? 0.18 : 0.10))
                        )
                }

                if fillsAvailableWidth {
                    Spacer(minLength: 4)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: fillsAvailableWidth ? .infinity : nil)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .fill(pillFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .strokeBorder(pillBorder, lineWidth: 0.6)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Theme.Animation.hover) {
                isHovered = hovering
            }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(options) { option in
                    TranslationPickMenuRow(
                        title: option.title,
                        isSelected: option.value == selection
                    ) {
                        selection = option.value
                        isPresented = false
                    }
                }
            }
            .padding(5)
            .frame(minWidth: 168)
        }
        .help(help)
    }

    private var primaryText: Color { MonitorOverviewPalette.primary(colorScheme) }
    private var secondaryText: Color { MonitorOverviewPalette.secondary(colorScheme) }

    private var pillFill: Color {
        if colorScheme == .dark {
            return Color.white.opacity(isHovered || isPresented ? 0.10 : 0.06)
        }
        return isHovered || isPresented
            ? Color(red: 0xEE / 255.0, green: 0xF0 / 255.0, blue: 0xF4 / 255.0)
            : Color.white
    }

    private var pillBorder: Color {
        if isPresented {
            return TranslationPresentation.tint.opacity(0.45)
        }
        return colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07)
    }
}

/// popover 内单行：勾选当前值 + 行内 hover 高亮。
private struct TranslationPickMenuRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(TranslationPresentation.tint)
                    .opacity(isSelected ? 1 : 0)

                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)

                Spacer(minLength: 8)
            }
            .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(isHovered
                        ? (colorScheme == .dark
                            ? Color.white.opacity(0.10)
                            : Theme.accentColor.opacity(0.10))
                        : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Theme.Animation.hover) {
                isHovered = hovering
            }
        }
    }
}

/// 语言交换按钮：位于对称语言栏正中，尺寸 28×28pt 与两侧胶囊等高对齐。
struct TranslationSwapButton: View {
    let isEnabled: Bool
    let help: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(
                    isEnabled
                        ? (isHovered ? TranslationPresentation.tint : MonitorOverviewPalette.secondary(colorScheme))
                        : MonitorOverviewPalette.auxiliary(colorScheme).opacity(0.55)
                )
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .fill(buttonFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .strokeBorder(
                            colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                            lineWidth: isEnabled ? 0.6 : 0.4
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 7.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            withAnimation(Theme.Animation.hover) {
                isHovered = hovering
            }
        }
        .help(help)
    }

    private var buttonFill: Color {
        if colorScheme == .dark {
            return Color.white.opacity(isHovered && isEnabled ? 0.11 : 0.045)
        }
        if !isEnabled {
            return Color.white.opacity(0.55)
        }
        return isHovered
            ? Color(red: 0xEB / 255.0, green: 0xF2 / 255.0, blue: 0xFE / 255.0)
            : Color.white
    }
}

/// 顶栏图标按钮（设置 / 置顶）：统一 26×26pt 尺寸与悬停/激活态。
struct TranslationTopBarIconButton: View {
    let systemName: String
    var isActive: Bool = false
    let help: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(background)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Theme.Animation.hover) {
                isHovered = hovering
            }
        }
        .help(help)
    }

    private var foreground: Color {
        if isActive {
            return TranslationPresentation.tint
        }
        return isHovered
            ? MonitorOverviewPalette.primary(colorScheme)
            : MonitorOverviewPalette.secondary(colorScheme)
    }

    private var background: Color {
        if isActive {
            return TranslationPresentation.tint.opacity(colorScheme == .dark ? 0.22 : 0.13)
        }
        if isHovered {
            return MonitorOverviewPalette.hoverFill(colorScheme)
        }
        return Color.clear
    }
}

/// 卡片底栏微操作胶囊（粘贴 / 清空 / 手动翻译 / 复制）。
struct TranslationCardActionPill: View {
    enum Tone {
        case neutral
        case accent
        case success
    }

    var systemImage: String? = nil
    let title: String
    var shortcutHint: String? = nil
    var tone: Tone = .neutral
    var isLoading: Bool = false
    var isDisabled: Bool = false
    var help: String? = nil
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.85)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9.5, weight: .semibold))
                }

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                if let shortcutHint, !isLoading {
                    Text(shortcutHint)
                        .font(.system(size: 9.5, weight: .regular))
                        .opacity(0.72)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                Capsule(style: .continuous)
                    .fill(background)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(isDisabled)
        .onHover { hovering in
            withAnimation(Theme.Animation.hover) {
                isHovered = hovering
            }
        }
        .help(help ?? title)
    }

    private var foreground: Color {
        if isDisabled {
            return MonitorOverviewPalette.auxiliary(colorScheme).opacity(0.6)
        }
        switch tone {
        case .neutral:
            return isHovered
                ? MonitorOverviewPalette.primary(colorScheme)
                : MonitorOverviewPalette.secondary(colorScheme)
        case .accent:
            return TranslationPresentation.tint
        case .success:
            return Color(red: 0.14, green: 0.65, blue: 0.34)
        }
    }

    private var background: Color {
        if isDisabled {
            return Color.clear
        }
        switch tone {
        case .neutral:
            if isHovered {
                return colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
            }
            return colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035)
        case .accent:
            return TranslationPresentation.tint.opacity(
                isHovered
                    ? (colorScheme == .dark ? 0.24 : 0.16)
                    : (colorScheme == .dark ? 0.16 : 0.10)
            )
        case .success:
            return Color.green.opacity(colorScheme == .dark ? 0.18 : 0.12)
        }
    }
}
