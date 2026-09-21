import SwiftUI

/// 跟随鼠标的悬浮气泡锚挂 — 1×1 锚点 position 到光标处，气泡按 alignment 悬挂在锚点旁。
/// 用 alignment 悬挂而非 offset，无需预知气泡尺寸即可完成「上方悬挂 / 顶部翻转到下方」的避让。
struct CursorBubbleAnchor<Content: View>: View {
    let anchor: CGPoint
    let alignment: Alignment
    @ViewBuilder var content: Content

    var body: some View {
        // overlay 必须挂在 frame(1×1) 内层、position 外层：position 视图布局上吃满提议空间，
        // overlay 若挂其外层会以整个容器为对齐基准（实测贴容器边），而非 1×1 锚点。
        Color.clear
            .frame(width: 1, height: 1)
            .overlay(alignment: alignment) { content }
            .position(anchor)
            .allowsHitTesting(false)
    }
}

/// 光标气泡定位 — 纯函数：光标位置 + 容器尺寸 → 锚点与对齐方式。
/// 垂直：默认悬挂在光标上方，光标贴近容器顶（预估放不下气泡）时翻到光标下方；
/// 水平：左/中/右三档对齐，防止气泡左右出界被面板窗口裁剪。
enum CursorBubbleLocator {
    /// 气泡与光标的间距（避开指针本体）。
    static let gap: CGFloat = 12
    /// 两行气泡的预估高度（11pt 主行 + 10pt 次行 + 内边距），垂直翻转的粗粒度阈值。
    static let estimatedBubbleHeight: CGFloat = 36

    static func anchor(
        location: CGPoint,
        in size: CGSize,
        gap: CGFloat = CursorBubbleLocator.gap,
        estimatedBubbleHeight: CGFloat = CursorBubbleLocator.estimatedBubbleHeight
    ) -> (anchor: CGPoint, alignment: Alignment) {
        guard size.width > 0, size.height > 0 else {
            return (location, .bottom)
        }

        // 垂直：上方悬挂；顶部空间不足时翻到光标下方。
        let flipsBelow = location.y < estimatedBubbleHeight + gap
        let anchorY = flipsBelow ? location.y + gap : location.y - gap
        let vertical: VerticalAlignment = flipsBelow ? .top : .bottom

        // 水平三档：左 1/3 左贴、右 1/3 右贴、中间居中。
        let horizontal: HorizontalAlignment
        if location.x < size.width / 3 {
            horizontal = .leading
        } else if location.x > size.width * 2 / 3 {
            horizontal = .trailing
        } else {
            horizontal = .center
        }
        return (CGPoint(x: location.x, y: anchorY), Alignment(horizontal: horizontal, vertical: vertical))
    }
}
