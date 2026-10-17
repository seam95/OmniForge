import SwiftUI

/// 控制中心顶栏 Tab 主次分段标准宽度：
/// Claude Code / 余额 85pt，Codex / 用量 44pt。
enum PanelSegmentMetric {
    static let primaryTabWidth: CGFloat = 85
    static let secondaryTabWidth: CGFloat = 44
}

/// 分段选择器组件：
/// - `.capsule` 样式：轨道 + pill 胶囊分段（全宽等分或自适应紧凑），底块滑移。
/// - `.underline` 样式：现代极简文字 Tab + 底部 2pt 细指示线滑移，去除底轨与厚滑块。
/// 选中指示器统一经 matchedGeometry 在分段间平滑滑移；动画统一由 value 驱动。
/// Reduce Motion 下降级为就地透明度过渡，不做位置插值（SPEC §7.4.3）。
struct PanelSegmentedControl<Tag: Hashable>: View {
    /// 选中底块 matchedGeometry 标识：底块/下划线在分段间平滑滑移。
    /// （泛型类型不支持 static 存储属性，用实例常量。）
    private let activeIndicatorID = "panel-segment-active"

    enum Style: Equatable {
        case capsule(isFullWidth: Bool = true)
        case underline
    }

    typealias Metric = PanelSegmentMetric

    struct Option: Identifiable {
        let tag: Tag
        let title: String
        var width: CGFloat?
        var id: Tag { tag }

        init(tag: Tag, title: String, width: CGFloat? = nil) {
            self.tag = tag
            self.title = title
            self.width = width
        }
    }

    let options: [Option]
    @Binding var selection: Tag
    var style: Style
    var underlineColor: Color

    init(
        options: [Option],
        selection: Binding<Tag>,
        style: Style = .capsule(isFullWidth: true),
        underlineColor: Color = Theme.accentColor
    ) {
        self.options = options
        self._selection = selection
        self.style = style
        self.underlineColor = underlineColor
    }

    init(
        options: [Option],
        selection: Binding<Tag>,
        isFullWidth: Bool
    ) {
        self.options = options
        self._selection = selection
        self.style = .capsule(isFullWidth: isFullWidth)
        self.underlineColor = Theme.accentColor
    }

    @Namespace private var indicator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredTag: Tag?

    var body: some View {
        switch style {
        case .capsule(let isFullWidth):
            capsuleBody(isFullWidth: isFullWidth)
        case .underline:
            underlineBody
        }
    }

    // MARK: - 极简文字下划线样式

    private var underlineBody: some View {
        HStack(spacing: 20) {
            ForEach(options) { option in
                let isSelected = selection == option.tag
                Button {
                    selection = option.tag
                } label: {
                    VStack(spacing: 5) {
                        Text(option.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(
                                isSelected
                                    ? (colorScheme == .light ? Theme.Stats.text1 : Color.white)
                                    : (hoveredTag == option.tag
                                        ? (colorScheme == .light ? Theme.Stats.text1 : Color.white.opacity(0.85))
                                        : (colorScheme == .light ? Theme.Stats.text2 : Color.secondary))
                            )
                            .lineLimit(1)
                            .padding(.horizontal, 2)
                            .padding(.top, 2)
                            .frame(width: option.width)

                        ZStack {
                            if isSelected {
                                underlineIndicator(width: option.width)
                            } else {
                                Color.clear.frame(height: 2)
                            }
                        }
                        .frame(width: option.width)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(Theme.Animation.hover) {
                        hoveredTag = hovering ? option.tag : nil
                    }
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .animation(
            PageSwitchMotionToken.selectionIndicator(reduceMotion: reduceMotion),
            value: selection
        )
    }

    @ViewBuilder
    private func underlineIndicator(width: CGFloat? = nil) -> some View {
        if reduceMotion {
            Capsule()
                .fill(underlineColor)
                .frame(width: width, height: 2)
                .transition(.opacity)
        } else {
            Capsule()
                .fill(underlineColor)
                .frame(width: width, height: 2)
                .matchedGeometryEffect(id: activeIndicatorID, in: indicator)
        }
    }

    // MARK: - 胶囊轨道样式

    private func capsuleBody(isFullWidth: Bool) -> some View {
        let outerCornerRadius: CGFloat = isFullWidth ? 10 : 7
        let innerCornerRadius: CGFloat = isFullWidth ? 8 : 5.5

        return HStack(spacing: 0) {
            ForEach(options) { option in
                let isSelected = selection == option.tag
                Button {
                    selection = option.tag
                } label: {
                    Text(option.title)
                        .font(Theme.Stats.font12Medium)
                        .foregroundStyle(isSelected ? (colorScheme == .light ? Theme.Stats.text1 : Color.white) : (colorScheme == .light ? Theme.Stats.text2 : Color.secondary))
                        .lineLimit(1)
                        .frame(maxWidth: isFullWidth ? .infinity : nil)
                        .padding(.horizontal, isFullWidth ? 0 : 14)
                        .padding(.vertical, isFullWidth ? 6 : 4)
                        .background {
                            if isSelected {
                                capsuleIndicator(innerRadius: innerCornerRadius, isFullWidth: isFullWidth)
                            } else if hoveredTag == option.tag {
                                RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous)
                                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04))
                                    .transition(.opacity)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(Theme.Animation.hover) {
                        hoveredTag = hovering ? option.tag : nil
                    }
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .animation(
            PageSwitchMotionToken.selectionIndicator(reduceMotion: reduceMotion),
            value: selection
        )
        .padding(isFullWidth ? 3 : 2)
        .background(
            RoundedRectangle(cornerRadius: outerCornerRadius, style: .continuous)
                .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: outerCornerRadius, style: .continuous)
                .strokeBorder(
                    colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08),
                    lineWidth: 0.6
                )
        )
    }

    @ViewBuilder
    private func capsuleIndicator(innerRadius: CGFloat, isFullWidth: Bool) -> some View {
        if reduceMotion {
            RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                .fill(selectedFill)
                .shadow(color: Color.black.opacity(colorScheme == .light ? (isFullWidth ? 0.06 : 0.08) : 0.0), radius: isFullWidth ? 2 : 1.5, x: 0, y: isFullWidth ? 1 : 0.5)
                .transition(.opacity)
        } else {
            RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                .fill(selectedFill)
                .shadow(color: Color.black.opacity(colorScheme == .light ? (isFullWidth ? 0.06 : 0.08) : 0.0), radius: isFullWidth ? 2 : 1.5, x: 0, y: isFullWidth ? 1 : 0.5)
                .matchedGeometryEffect(id: activeIndicatorID, in: indicator)
        }
    }

    private var selectedFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Theme.Stats.cardBackground
    }
}
