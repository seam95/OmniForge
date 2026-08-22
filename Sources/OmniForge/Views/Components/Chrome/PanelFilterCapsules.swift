import SwiftUI

/// 少量选项的 capsule 过滤组（如 Listen / All）。
struct PanelFilterCapsules<Tag: Hashable>: View {
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
                        .font(Theme.Stats.font10Regular)
                        .textCase(.uppercase)
                        .foregroundStyle(isSelected ? (colorScheme == .light ? Theme.Stats.text1 : Color.white) : (colorScheme == .light ? Theme.Stats.text2 : Color.secondary))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(colorScheme == .light ? Theme.Stats.cardBackground : Color.white.opacity(0.14))
                                    .shadow(color: Color.black.opacity(colorScheme == .light ? 0.06 : 0.0), radius: 2, x: 0, y: 1)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2.5)
        .background(
            Capsule(style: .continuous)
                .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.08))
        )
    }
}
