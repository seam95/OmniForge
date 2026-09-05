import SwiftUI

/// 轨道 + 等分 pill 分段，外观对齐控制中心稿，替代系统 SegmentedControl。
/// 选中底块经 matchedGeometry 在分段间平滑滑移；动画统一由 value 驱动，
/// 使用方任意赋值路径（点击、外部 binding）均同享一套转场。
/// Reduce Motion 下降级为就地底块的透明度过渡，不做位置插值（SPEC §7.4.3）。
struct PanelSegmentedControl<Tag: Hashable>: View {
    /// 选中底块 matchedGeometry 标识：底块在分段间平滑滑移。
    /// （泛型类型不支持 static 存储属性，用实例常量。）
    private let activeIndicatorID = "panel-segment-active"

    struct Option: Identifiable {
        let tag: Tag
        let title: String
        var id: Tag { tag }
    }

    let options: [Option]
    @Binding var selection: Tag

    @Namespace private var indicator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let isSelected = selection == option.tag
                Button {
                    selection = option.tag
                } label: {
                    Text(option.title)
                        .font(Theme.Stats.font12Medium)
                        .foregroundStyle(isSelected ? (colorScheme == .light ? Theme.Stats.text1 : Color.white) : (colorScheme == .light ? Theme.Stats.text2 : Color.secondary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if isSelected {
                                selectedIndicator
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .animation(
            PageSwitchMotionToken.selectionIndicator(reduceMotion: reduceMotion),
            value: selection
        )
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.06))
        )
    }

    /// 选中底块：常规经 matchedGeometry 滑移；Reduce Motion 下就地渲染 +
    /// 透明度过渡（新旧底块交叉淡切，无位置插值，SPEC §7.4.3）。
    @ViewBuilder
    private var selectedIndicator: some View {
        if reduceMotion {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selectedFill)
                .shadow(color: Color.black.opacity(colorScheme == .light ? 0.06 : 0.0), radius: 2, x: 0, y: 1)
                .transition(.opacity)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selectedFill)
                .shadow(color: Color.black.opacity(colorScheme == .light ? 0.06 : 0.0), radius: 2, x: 0, y: 1)
                .matchedGeometryEffect(id: activeIndicatorID, in: indicator)
        }
    }

    private var selectedFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Theme.Stats.cardBackground
    }
}
