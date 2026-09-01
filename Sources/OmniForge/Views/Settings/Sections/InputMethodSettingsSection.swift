import SwiftUI

struct InputMethodSettingsSection: View {
    @ObservedObject var state: AppState

    private var isEnabled: Bool { state.lockState?.isLocked == true }

    var body: some View {
        Section(state.l10n.s.featureHubNameInputLock) {
            Toggle(isOn: Binding(
                get: { isEnabled },
                set: { state.setLocked($0) }
            )) {
                InfoHintLabel(state.l10n.s.actionLock, hint: state.l10n.s.featureHubDescInputLock)
            }
            FeatureRunStateRow(
                state: state.inputMethodRunState,
                strings: state.l10n.s,
                retry: state.retryInputMethod
            )
        }

        Section(state.l10n.s.settingsInputMethodSection) {
            if state.inputSources.isEmpty {
                Text(state.l10n.s.controlcenterInputLockNoSource)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(state.inputSources) { source in
                    inputSourceRow(source)
                }
            }
        }
        .disabled(!isEnabled)
        .onAppear { state.refreshInputSources() }
    }

    private func inputSourceRow(_ source: InputSource) -> some View {
        let isSelected = source.id == state.selectedInputSourceID
        let isSelectable = source.isSelectable && source.isEnabled

        return Button {
            guard isSelectable else { return }
            state.selectInputSource(id: source.id)
        } label: {
            HStack(spacing: 10) {
                if let icon = source.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text(source.name)
                    .foregroundStyle(isSelectable ? .primary : .secondary)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable)
    }
}
