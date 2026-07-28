import SwiftUI

struct GeneralSettingsView: View {
    let state: AppState

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

                Toggle(state.l10n.s.settingsHideDockIcon, isOn: Binding(
                    get: { state.hideDockIcon },
                    set: { state.setHideDockIcon($0) }
                ))
                .accessibilityIdentifier(SettingsAccessibilityID.generalHideDockIcon.rawValue)
            }
        }
        .settingsPageStyle()
    }
}
