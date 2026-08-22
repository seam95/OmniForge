import AppKit
import SwiftUI

struct MainPanelView: View {
    @ObservedObject var state: AppState
    let onOpenClipboard: () -> Void
    var onOpenSettings: () -> Void = {}
    @State private var hoveredSourceID: String?
    @Environment(\.colorScheme) private var colorScheme

    private var accentColor: Color {
        Theme.Stats.cpu
    }

    private var headerTitle: String {
        let id = state.selectedInputSourceID ?? ""
        return state.inputSources.first(where: { $0.id == id })?.name ?? "OmniForge"
    }

    private func card(for source: InputSource) -> some View {
        let isSelected = state.selectedInputSourceID == source.id
        let isHovered = hoveredSourceID == source.id
        let isDisabled = !source.isSelectable || !source.isEnabled

        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                state.selectInputSource(id: source.id)
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .font(Theme.Stats.font13SemiBold)
                        .foregroundStyle(isDisabled ? (colorScheme == .light ? Theme.Stats.text3 : Color.secondary) : (colorScheme == .light ? Theme.Stats.text1 : Color.primary))
                        .lineLimit(1)

                    Text(source.id)
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Group {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
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
                    .fill(cardFill(isSelected: isSelected, isHovered: isHovered))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            hoveredSourceID = hovering ? source.id : nil
        }
    }

    private func cardFill(isSelected: Bool, isHovered: Bool) -> Color {
        if colorScheme == .dark {
            return isSelected ? Color.white.opacity(0.14) : Color.white.opacity(isHovered ? 0.10 : 0.06)
        }
        if isSelected {
            return Theme.Stats.cardBackground
        }
        return isHovered ? Color(red: 0xFA/255.0, green: 0xFA/255.0, blue: 0xFC/255.0) : Theme.Stats.cardBackground
    }

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Theme.Stats.panelBackground)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    Text(headerTitle)
                        .font(Theme.Stats.font13SemiBold)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Spacer(minLength: 8)

                    Button {
                        onOpenClipboard()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(colorScheme == .light ? Theme.Stats.text2 : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)

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
                    .layoutPriority(1)
                }

                Text(state.l10n.s.panelSelectSource)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(state.inputSources) { source in
                            card(for: source)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollDisabled(state.inputSources.count <= 3)
                .scrollIndicators(.hidden)
                .frame(maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Divider()
                    .overlay(colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08))
                    .padding(.vertical, 2)

                HStack {
                    FooterButton(label: state.l10n.s.settingsTitle, systemImage: "gearshape") {
                        onOpenSettings()
                    }

                    Spacer()

                    FooterButton(label: state.l10n.s.actionQuit, systemImage: nil) {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 340, alignment: .topLeading)
        .onAppear {
            state.refreshInputSources()
        }
    }
}
