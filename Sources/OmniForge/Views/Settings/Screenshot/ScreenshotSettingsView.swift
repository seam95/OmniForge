import SwiftUI

/// 截图独立设置 Tab（决策 8.5-10）。
struct ScreenshotSettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var runtime = FeatureRuntime.shared

    var body: some View {
        Form {
            ScreenshotSettingsSection(
                state: state,
                manager: runtime.manager(for: .screenshot, as: ScreenshotFeatureManager.self)
            )
        }
        .settingsPageStyle()
        .id(runtime.revision)
    }
}
