import SwiftUI

/// 轨道 + 等分 pill 分段，外观对齐控制中心稿，替代系统 SegmentedControl。
struct PanelSegmentedControl<Tag: Hashable>: View {
    struct Option: Identifiable {
        let tag: Tag
        let title: String
        var id: Tag { tag }
    }

    let options: [Option]
    @Binding var selection: Tag

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let isSelected = selection == option.tag
                Button {
                    selection = option.tag
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selectedFill)
                                    .shadow(color: Color.black.opacity(0.08), radius: 3, x: 0, y: 1)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var selectedFill: Color {
        colorScheme == .dark
            ? Color.primary.opacity(0.12)
            : Color.white.opacity(0.92)
    }
}
