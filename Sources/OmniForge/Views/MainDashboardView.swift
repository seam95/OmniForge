import AppKit
import SwiftUI

struct MainDashboardView: View {
    @ObservedObject var state: AppState
    var onOpenSettings: () -> Void = {}

    @State private var hoveredSourceID: String?
    @Environment(\.colorScheme) private var colorScheme

    private var accentColor: Color {
        Theme.accentColor
    }

    private var cardBackgroundMaterial: Material {
        colorScheme == .dark ? .regularMaterial : .ultraThinMaterial
    }

    private var cardSelectedBackgroundMaterial: Material {
        colorScheme == .dark ? .thickMaterial : .regularMaterial
    }

    private var separatorStrokeColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.12)
    }

    private var selectedInputSourceName: String {
        let id = state.selectedInputSourceID ?? ""
        return state.inputSources.first(where: { $0.id == id })?.name ?? state.l10n.s.appTitle
    }

    private var hasSelectableInputSource: Bool {
        state.inputSources.contains(where: { $0.isSelectable && $0.isEnabled })
    }

    private func inputSourceCard(for source: InputSource) -> some View {
        let isSelected = state.selectedInputSourceID == source.id
        let isHovered = hoveredSourceID == source.id
        let isDisabled = !source.isSelectable || !source.isEnabled

        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                state.selectInputSource(id: source.id)
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(isDisabled ? .secondary : .primary)
                        .lineLimit(1)

                    Text(source.id)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Group {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(accentColor)
                    } else {
                        Image(systemName: "checkmark")
                            .hidden()
                    }
                }
                .frame(width: 16, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? cardSelectedBackgroundMaterial : cardBackgroundMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? accentColor.opacity(0.55) : separatorStrokeColor,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .shadow(
                color: Color.black.opacity(
                    isDisabled
                        ? 0
                        : (isHovered ? (colorScheme == .dark ? 0.25 : 0.10) : (colorScheme == .dark ? 0.18 : 0.06))
                ),
                radius: isHovered ? 10 : 6,
                x: 0,
                y: isHovered ? 4 : 2
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || state.lockState?.isLocked != true)
        .onHover { hovering in
            hoveredSourceID = hovering ? source.id : nil
        }
    }

    private var sectionCard: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(cardBackgroundMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(separatorStrokeColor, lineWidth: 1)
            )
    }

    private func featureRow(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(accentColor)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedInputSourceName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(state.l10n.s.controlcenterInputLockDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Toggle(
                    state.l10n.s.actionLock,
                    isOn: Binding(
                        get: { state.lockState?.isLocked == true },
                        set: { state.setLocked($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(accentColor)
                .accessibilityLabel(state.l10n.s.actionLock)
                .disabled(state.lockState == nil)
            }

            Text(state.l10n.s.panelSelectSource)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(state.inputSources) { source in
                        inputSourceCard(for: source)
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 2)
            }
            .frame(height: 188)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .disabled(state.lockState?.isLocked != true)

            if !hasSelectableInputSource {
                Text(state.l10n.s.controlcenterInputLockNoSource)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                featureRow(
                    title: state.l10n.s.controlcenterClipboardTitle,
                    subtitle: state.isClipboardFeatureEnabled
                        ? state.l10n.s.controlcenterClipboardEnabled
                        : state.l10n.s.controlcenterClipboardDisabled,
                    isOn: Binding(
                        get: { state.isClipboardFeatureEnabled },
                        set: { state.setClipboardFeatureEnabled($0) }
                    )
                )
            }
            .padding(12)
            .background(sectionCard)

            HStack {
                Button {
                    onOpenSettings()
                } label: {
                    Label(state.l10n.s.controlcenterOpenSettings, systemImage: "gearshape")
                }

                Spacer()

                Button(state.l10n.s.actionQuit) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
