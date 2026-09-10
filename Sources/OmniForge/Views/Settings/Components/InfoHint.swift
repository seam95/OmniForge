import SwiftUI

/// 说明提示图标：平时淡灰，悬停高亮并立即弹出说明气泡。
/// 用于把设置项的说明文字收敛到行内图标后，避免整行平铺。
/// 气泡走 popover 而非系统 `.help`：系统 tooltip 有约 1 秒固定延迟，
/// 等待期间用户会误以为提示不显示；popover 由悬停直接驱动，近乎立即出现。
struct InfoHintButton: View {
    let text: String

    @State private var isHovering = false
    @State private var showsBubble = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 12))
            .foregroundStyle(isHovering ? Color.accentColor : Color.secondary.opacity(0.55))
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    // 120ms 防抖：鼠标扫过整列设置项时不逐个闪气泡；感知上仍是立即。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        if isHovering { showsBubble = true }
                    }
                } else {
                    showsBubble = false
                }
            }
            .popover(isPresented: $showsBubble, arrowEdge: .top) {
                Text(text)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: 280, alignment: .leading)
                    .fixedSize()
            }
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
