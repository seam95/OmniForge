import SwiftUI

/// 屏幕清洁遮罩内容：纯黑/白底（看灰尘与指印）、中央提示 5 秒淡出（SPEC D8）、
/// 长按解锁进度环；键盘清洁提示窗复用同一视图：无底色、提示常驻整个会话。
struct CleaningOverlayView: View {
    @ObservedObject var model: CleaningOverlayViewModel

    private var foreground: Color {
        // 无底色提示窗跟随系统外观，保证深浅色下均可读。
        guard model.showsSolidBackground else { return .primary.opacity(0.85) }
        return model.style == .black ? Color.white.opacity(0.6) : Color.black.opacity(0.55)
    }

    private var isRingVisible: Bool {
        (model.holdProgress ?? 0) > 0
    }

    var body: some View {
        ZStack {
            if model.showsSolidBackground {
                (model.style == .black ? Color.black : Color.white)
                    .ignoresSafeArea()
            }

            VStack(spacing: 16) {
                if model.isHintVisible {
                    hintView
                        .transition(.opacity)
                }
                // 进度环常驻槽位：占位固定，提示文字不会因环出现而跳动。
                holdRing(progress: model.holdProgress ?? 0)
                    .opacity(isRingVisible ? 1 : 0)
            }
        }
        // 无纯色底（键盘清洁提示窗）时 ZStack 会收缩到内容大小，需显式撑满面板才能居中。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.4), value: model.isHintVisible)
        .animation(.linear(duration: 0.06), value: model.holdProgress)
    }

    /// 中央提示：遮罩上直接排字；无底色提示窗加胶囊底，保证任意壁纸下可读。
    @ViewBuilder
    private var hintView: some View {
        if model.showsSolidBackground {
            hintText
                .padding(.horizontal, 24)
        } else {
            hintText
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                )
        }
    }

    private var hintText: some View {
        Text(model.hintText)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(foreground)
            .multilineTextAlignment(.center)
    }

    /// 细进度环：满圈即达成 3 秒长按。
    private func holdRing(progress: Double) -> some View {
        ZStack {
            Circle()
                .stroke(foreground.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(foreground, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 64, height: 64)
    }
}
