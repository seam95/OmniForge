import SwiftUI

/// 说明提示图标：平时淡灰，悬停高亮并悬浮展示说明气泡。
/// 用于把设置项的说明文字收敛到行内图标后，避免整行平铺。
struct InfoHintButton: View {
    let text: String

    @State private var isHovering = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 12))
            .foregroundStyle(isHovering ? Color.accentColor : Color.secondary.opacity(0.55))
            .onHover { isHovering = $0 }
            .help(text)
            .accessibilityLabel(text)
    }
}

/// 设置项标题 + 说明图标的组合标签，供 Toggle / Picker / LabeledContent 的 label 闭包使用。
struct InfoHintLabel: View {
    let title: String
    let hint: String?

    init(_ title: String, hint: String? = nil) {
        self.title = title
        self.hint = hint
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            if let hint, !hint.isEmpty {
                InfoHintButton(text: hint)
            }
        }
    }
}
