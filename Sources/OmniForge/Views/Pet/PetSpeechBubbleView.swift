import SwiftUI

/// 气泡视图模型：控制器在展示 / 翻转 / 隐藏时更新，SwiftUI 侧驱动淡入淡出。
@MainActor
final class PetBubbleViewModel: ObservableObject {
    @Published var text: String = ""
    @Published var tailDown = true
    @Published var size: CGSize = .zero
    /// false 时视图淡出；控制器在淡出结束后 orderOut。
    @Published var visible = false
}

/// 桌宠对话气泡：圆角矩形 + 指向宠物的尾巴，点击关闭。
/// 语义色（controlBackground / separator / primary）自适应系统深浅模式；
/// 投影交给面板系统投影（hasShadow，跟随含尾巴的内容轮廓）。
struct PetSpeechBubbleView: View {
    @ObservedObject var model: PetBubbleViewModel
    /// 点击气泡回调（仅关气泡，反应动画不受影响）。
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // 层序：矩形填充 → 矩形描边 → 尾巴填充（盖住尾巴基线处的描边缝）→ 尾巴两斜边描线。
            bubbleBody
                .fill(Color(nsColor: .controlBackgroundColor))
            bubbleBody
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            PetBubbleTailFill(tailDown: model.tailDown)
                .fill(Color(nsColor: .controlBackgroundColor))
            PetBubbleTailEdges(tailDown: model.tailDown)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            Text(model.text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                // 文本在不含尾巴的矩形区内居中。
                .padding(model.tailDown ? .bottom : .top, PetBubbleMetrics.tailHeight)
                .frame(
                    width: model.size.width,
                    height: model.size.height,
                    alignment: model.tailDown ? .top : .bottom
                )
        }
        .frame(width: model.size.width, height: model.size.height)
        .contentShape(Rectangle())
        .opacity(model.visible ? 1 : 0)
        .animation(.easeOut(duration: model.visible ? 0.15 : 0.2), value: model.visible)
        .onTapGesture { onDismiss() }
    }

    /// 气泡主体圆角矩形：尾巴侧预留尾巴高度的空区。
    private var bubbleBody: Path {
        let bodyHeight = max(model.size.height - PetBubbleMetrics.tailHeight, 8)
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .path(in: CGRect(
                origin: CGPoint(x: 0, y: model.tailDown ? 0 : PetBubbleMetrics.tailHeight),
                size: CGSize(width: model.size.width, height: bodyHeight)
            ))
    }
}

/// 气泡几何常量（视图与窗口量尺共用）。
enum PetBubbleMetrics {
    /// 尾巴高度（点）：全帧中尾巴侧预留的空区。
    static let tailHeight: CGFloat = 6
    /// 尾巴宽度（点）。
    static let tailWidth: CGFloat = 10
}

/// 尾巴三角填充：基线埋入气泡矩形 1pt，与矩形同色无缝相接。
struct PetBubbleTailFill: Shape {
    let tailDown: Bool

    func path(in rect: CGRect) -> Path {
        let half = PetBubbleMetrics.tailWidth / 2
        let baseY = tailDown
            ? rect.height - PetBubbleMetrics.tailHeight
            : PetBubbleMetrics.tailHeight
        let tipY = tailDown ? rect.height : 0
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - half, y: baseY))
        path.addLine(to: CGPoint(x: rect.midX + half, y: baseY))
        path.addLine(to: CGPoint(x: rect.midX, y: tipY))
        path.closeSubpath()
        return path
    }
}

/// 尾巴两条斜边的描线（基线不描，避免与矩形描边形成接缝线）。
struct PetBubbleTailEdges: Shape {
    let tailDown: Bool

    func path(in rect: CGRect) -> Path {
        let half = PetBubbleMetrics.tailWidth / 2
        let baseY = tailDown
            ? rect.height - PetBubbleMetrics.tailHeight
            : PetBubbleMetrics.tailHeight
        let tipY = tailDown ? rect.height : 0
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - half, y: baseY))
        path.addLine(to: CGPoint(x: rect.midX, y: tipY))
        path.addLine(to: CGPoint(x: rect.midX + half, y: baseY))
        return path
    }
}
