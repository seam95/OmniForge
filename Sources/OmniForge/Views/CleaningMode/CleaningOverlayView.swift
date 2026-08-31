import SwiftUI

/// 屏幕清洁遮罩内容：纯黑/白底（看灰尘与指印）、中央提示 5 秒淡出（SPEC D8）、
/// 长按解锁进度环（仅屏幕清洁模式下由拦截层驱动）。
struct CleaningOverlayView: View {
    @ObservedObject var model: CleaningOverlayViewModel
    let strings: Strings

    private var foreground: Color {
        // 无底色提示窗跟随系统外观，保证深浅色下均可读。
        guard model.showsSolidBackground else { return .primary.opacity(0.75) }
        return model.style == .black ? Color.white.opacity(0.6) : Color.black.opacity(0.55)
    }

    var body: some View {
        ZStack {
            if model.showsSolidBackground {
                (model.style == .black ? Color.black : Color.white)
                    .ignoresSafeArea()
            }

            if model.isHintVisible {
                Text(strings.cleaningModeLockedHint)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(foreground)
                    .padding(.horizontal, 24)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            if let progress = model.holdProgress, progress > 0 {
                holdRing(progress: progress)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: model.isHintVisible)
        .animation(.linear(duration: 0.06), value: model.holdProgress)
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
