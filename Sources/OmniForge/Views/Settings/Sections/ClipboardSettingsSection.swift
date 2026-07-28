import KeyboardShortcuts
import SwiftUI

struct ClipboardSettingsSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        Section(state.l10n.s.featureHubNameClipboardHistory) {
            Toggle(state.l10n.s.controlcenterClipboardTitle, isOn: Binding(
                get: { state.isClipboardFeatureEnabled },
                set: { state.setClipboardFeatureEnabled($0) }
            ))
            Text(
                state.isClipboardFeatureEnabled
                    ? state.l10n.s.controlcenterClipboardEnabled
                    : state.l10n.s.controlcenterClipboardDisabled
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 20)
        }

        if let history = state.clipboardHistory,
           let hotkey = state.clipboardHotkey {
            Section(state.l10n.s.settingsClipboardSection) {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.l10n.s.settingsClipboardHotkey)
                    Spacer()
                    HotkeyRecorderView(
                        displayText: hotkey.hotkey.displayString,
                        onShortcutChanged: hotkey.handleRecorderChange,
                        l10n: state.l10n
                    )
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(state.l10n.s.settingsClipboardRetentionDays)
                    Spacer()
                    NumericStepperField(
                        value: Binding(
                            get: { history.retentionDays },
                            set: { history.retentionDays = $0 }
                        ),
                        range: ClipboardHistoryLimits.minRetentionDays...ClipboardHistoryLimits.maxRetentionDays,
                        step: 1
                    )
                    Text(state.l10n.s.settingsDays)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(state.l10n.s.settingsClipboardMaxEntries)
                    Spacer()
                    NumericStepperField(
                        value: Binding(
                            get: { history.maxEntries },
                            set: { history.maxEntries = $0 }
                        ),
                        range: ClipboardHistoryLimits.minMaxEntries...ClipboardHistoryLimits.maxMaxEntries,
                        step: ClipboardHistoryLimits.maxEntriesStep
                    )
                    Text(state.l10n.s.settingsEntries)
                }
            }
            .disabled(!state.isClipboardFeatureEnabled)
        }
    }
}

/// 可输入数字框 + 步进箭头复用组件。
/// 用本地文本缓冲隔离输入，避免逐字符触发上层钳位；回车/失焦时一次性提交。
private struct NumericStepperField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    @State private var text: String = ""
    @State private var initialized = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            TextField("", text: $text)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 56, idealWidth: CGFloat(max(56, String(range.upperBound).count * 12 + 16)))
                .focused($isFocused)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .onChange(of: value) { _, newValue in
                    if !isFocused { text = String(newValue) }
                }

            Stepper(value: $value, in: range, step: step) { EmptyView() }
                .labelsHidden()
        }
        .onAppear {
            if !initialized {
                text = String(value)
                initialized = true
            }
        }
    }

    /// 解析缓冲文本 → 钳位到合法范围 → 回写。
    private func commit() {
        let parsed = Int(text.trimmingCharacters(in: .whitespaces)) ?? value
        let normalized = min(max(parsed, range.lowerBound), range.upperBound)
        value = normalized
        text = String(normalized)
    }
}
