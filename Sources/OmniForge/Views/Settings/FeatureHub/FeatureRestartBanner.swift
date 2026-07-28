import SwiftUI

/// 重启提示 banner — 当 `needsRestartToUnload` 为 true 时展示，
/// 提醒用户卸载的特性仍驻留内存，点击按钮重启应用。
struct FeatureRestartBanner: View {
    @ObservedObject var runtime: FeatureRuntime
    let strings: Strings

    var body: some View {
        if runtime.needsRestartToUnload {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                Text(strings.featureHubRestartNote)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                Button(strings.featureHubRestartButton) {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
        }
    }
}
