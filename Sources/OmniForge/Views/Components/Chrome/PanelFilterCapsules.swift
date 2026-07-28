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

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let isSelected = selection == option.tag
                Button {
                    selection = option.tag
                } label: {
                    Text(option.title)
                        .font(.system(size: 9, weight: .bold))
                        .textCase(.uppercase)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}
