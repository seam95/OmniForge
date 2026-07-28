import SwiftUI

/// 状态 tint 胶囊：字色 + 同色 15% 底，对齐监控总览「正常」pill。
struct StatusTintBadge: View {
    let text: String
    var tint: Color = .green

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .textCase(.uppercase)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.15))
            )
            .lineLimit(1)
    }
}
