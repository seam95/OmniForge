import SwiftUI

// MARK: - 浮窗工具条控件

/// 胶囊菜单项：`value` 参与选择比较，`title` 为本地化显示名。
struct TranslationPickOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
}

/// 胶囊菜单：自绘按钮 + 系统 popover 列表。
///
/// 不用 `Menu` / `Picker(.menu)` 的原因：两者都会绘制系统按钮底色或把指示器
/// 排到前导，无法贴合浮窗工具条；popover 列表由本视图排版，菜单外观仍是
/// 系统 NSPopover（圆角、阴影、Esc 关闭）。
struct TranslationPickMenu<Value: Hashable>: View {
    let options: [TranslationPickOption<Value>]
    /// 当前选中项的显示文本（由调用方按本地化规则解析，避免视图内重复映射）。
    let title: String
    @Binding var selection: Value
    let help: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPresented = false
    @State private var isHovered = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(secondaryText)
            }
            .foregroundStyle(primaryText)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(isHovered || isPresented
                        ? MonitorOverviewPalette.hoverFill(colorScheme)
                        : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Theme.Animation.hover) {
                isHovered = hovering
            }
        }
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
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
            .padding(4)
            .frame(minWidth: 150)
        }
        .help(help)
    }

    private var primaryText: Color { MonitorOverviewPalette.primary(colorScheme) }
    private var secondaryText: Color { MonitorOverviewPalette.secondary(colorScheme) }
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
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(isSelected ? 1 : 0)

                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)

                Spacer(minLength: 8)
            }
            .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered
                        ? (colorScheme == .dark
                            ? Color.white.opacity(0.1)
                            : Theme.accentColor.opacity(0.12))
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

/// 语言交换小按钮：与两侧菜单同一行，尺寸压到 20pt 保持工具条高度。
struct TranslationSwapButton: View {
    let isEnabled: Bool
    let help: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(
                    isEnabled
                        ? MonitorOverviewPalette.secondary(colorScheme)
                        : MonitorOverviewPalette.auxiliary(colorScheme)
                )
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(isHovered && isEnabled
                            ? MonitorOverviewPalette.hoverFill(colorScheme)
                            : Color.clear)
                )
                .contentShape(Rectangle())
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
}

/// 工具条控件组底板：浅色下浅灰轨道，深色下低透明白，与分段控件同语言。
struct TranslationControlGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08),
                    lineWidth: 0.6
                )
        )
    }
}
