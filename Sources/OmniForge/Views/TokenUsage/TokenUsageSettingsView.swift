import SwiftUI

/// 「Token 用量」设置页 — 两态：未安装仅安装开关；已安装为 [通用][提供商][告警] 子分段。
/// 子分段的具体表单在 #10 落地，本骨架只搭结构。
struct TokenUsageSettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var runtime = FeatureRuntime.shared
    @State private var section: TokenUsageSettingsSection = .general

    private var isInstalled: Bool {
        runtime.isAvailable(.tokenUsage)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isInstalled {
                uninstalledContent
            } else {
                installedContent
            }
        }
    }

    private var uninstalledContent: some View {
        Form {
            Section {
                Toggle(state.l10n.s.featureHubNameTokenUsage, isOn: Binding(
                    get: { false },
                    set: { runtime.setAvailable(.tokenUsage, $0) }
                ))
                .accessibilityIdentifier(SettingsAccessibilityID.tokenUsageEnabled.rawValue)
            } footer: {
                Text(state.l10n.s.tokenSettingsCaption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsPageStyle()
    }

    private var installedContent: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(TokenUsageSettingsSection.allCases) { item in
                    Text(item.title(in: state.l10n.s)).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(SettingsAccessibilityID.tokenUsageSegment.rawValue)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            // 子分段表单自 #10 起落地。
            Text(state.l10n.s.tokenSettingsCaption)
                .font(Theme.Stats.font11Regular)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(20)
        }
    }
}
