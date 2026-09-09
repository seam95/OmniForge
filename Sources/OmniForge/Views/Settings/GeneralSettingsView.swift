import SwiftUI

struct GeneralSettingsView: View {
    let state: AppState
    @ObservedObject private var appearance: AppearanceSettings

    init(state: AppState) {
        self.state = state
        _appearance = ObservedObject(wrappedValue: state.appearance)
    }

    var body: some View {
        Form {
            Section(state.l10n.s.settingsGeneralSection) {
                Picker(state.l10n.s.settingsLanguage, selection: Binding(
                    get: { state.l10n.language == .systemDefault ? "" : state.l10n.language.rawValue },
                    set: { newValue in
                        if newValue.isEmpty {
                            state.l10n.setLanguage(nil)
                        } else if let lang = AppLanguage(rawValue: newValue) {
                            state.l10n.setLanguage(lang)
                        }
                        // 输入源显示名对齐应用语言，切换后立即刷新列表。
                        state.refreshInputSources()
                    }
                )) {
                    Text(state.l10n.s.settingsSystem).tag("")
                    Text(AppLanguage.en.displayName).tag(AppLanguage.en.rawValue)
                    Text(AppLanguage.zhHans.displayName).tag(AppLanguage.zhHans.rawValue)
                }
                .accessibilityIdentifier(SettingsAccessibilityID.generalLanguage.rawValue)

                Picker(selection: Binding(
                    get: { appearance.mode.rawValue },
                    set: { newValue in
                        if let mode = AppearanceMode(rawValue: newValue) {
                            appearance.setMode(mode)
                        }
                    }
                )) {
                    Text(state.l10n.s.settingsAppearanceSystem).tag(AppearanceMode.system.rawValue)
                    Text(state.l10n.s.settingsAppearanceLight).tag(AppearanceMode.light.rawValue)
                    Text(state.l10n.s.settingsAppearanceDark).tag(AppearanceMode.dark.rawValue)
                } label: {
                    // 既定规范：新设置项说明不平铺，走 InfoHint 气泡。
                    InfoHintLabel(state.l10n.s.settingsAppearance, hint: state.l10n.s.settingsAppearanceHint)
                }
                .accessibilityIdentifier(SettingsAccessibilityID.generalAppearance.rawValue)

                Toggle(state.l10n.s.settingsLaunchAtLogin, isOn: Binding(
                    get: { state.launchAtLogin.isEnabled },
                    set: { state.launchAtLogin.setEnabled($0) }
                ))
                .accessibilityIdentifier(SettingsAccessibilityID.generalLaunchAtLogin.rawValue)

                if let error = state.launchAtLogin.lastError {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(SettingsAccessibilityID.generalLaunchAtLoginError.rawValue)
                }

                Toggle(isOn: Binding(
                    get: { state.hideDockIcon },
                    set: { state.setHideDockIcon($0) }
                )) {
                    InfoHintLabel(state.l10n.s.settingsHideDockIcon, hint: state.l10n.s.settingsHideDockIconHint)
                }
                .accessibilityIdentifier(SettingsAccessibilityID.generalHideDockIcon.rawValue)
            }
        }
        .settingsPageStyle()
    }
}
