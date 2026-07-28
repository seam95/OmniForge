import AppKit
import SwiftUI

struct MainPanelView: View {
    @ObservedObject var state: AppState
    let onOpenClipboard: () -> Void
    var onOpenSettings: () -> Void = {}
    @State private var hoveredSourceID: String?
    @Environment(\.colorScheme) private var colorScheme

    private var accentColor: Color {
        Color(.sRGB, red: 0.14, green: 0.45, blue: 0.98, opacity: 1)
    }

    private var backgroundGradientColors: [Color] {
        [
            Color(nsColor: .windowBackgroundColor),
            Color(nsColor: .controlBackgroundColor)
        ]
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
                        isSelected
                            ? accentColor.opacity(0.55)
                            : separatorStrokeColor,
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
        .disabled(isDisabled)
        .onHover { hovering in
            hoveredSourceID = hovering ? source.id : nil
        }
    }

    private func footerButton<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        label()
            .foregroundStyle(.primary)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(cardBackgroundMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(separatorStrokeColor, lineWidth: 1)
            )
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: backgroundGradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(accentColor.opacity(colorScheme == .dark ? 0.16 : 0.10))
                .blur(radius: 22)
                .frame(width: 220, height: 220)
                .offset(x: 120, y: -120)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Text(headerTitle)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Spacer(minLength: 8)

                    Button {
                        onOpenClipboard()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
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
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                // 改进布局：使用最小高度确保输入法列表能够正常显示
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(state.inputSources) { source in
                            card(for: source)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
                .scrollDisabled(state.inputSources.count <= 3)
                .scrollIndicators(.hidden)
                .frame(maxHeight: 180) // 刚好显示 3 个项目 (52 * 3 + 8 * 2 + 8 padding)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Divider()
                    .padding(.vertical, 4)

                HStack {
                    Button {
                        onOpenSettings()
                    } label: {
                        footerButton {
                            Image(systemName: "gearshape")
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button(state.l10n.s.actionQuit) {
                        NSApplication.shared.terminate(nil)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(cardBackgroundMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(separatorStrokeColor, lineWidth: 1)
                    )
                }
            }
            .padding(14)
        }
        // MenuBarExtra 的 popover 在尺寸推导上偏保守，这里强制给出理想尺寸，避免内容被压缩到"什么都看不见"。
        .frame(width: 340, alignment: .topLeading)
        .onAppear {
            state.refreshInputSources()
        }
    }
}
