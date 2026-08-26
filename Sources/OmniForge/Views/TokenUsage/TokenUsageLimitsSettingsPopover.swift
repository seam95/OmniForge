import SwiftUI
import AppKit

/// 「限额显示」齿轮弹层：
/// 剩余/已用口径 + 额度重置提示/撒花开关 + 已配置 provider 的显隐开关与拖拽排序。
/// 排序结果写回 `providerOrder`（未配置项保持原位）；显隐写回 `hiddenProviders`。
struct TokenUsageLimitsSettingsPopover: View {
    @ObservedObject var preferences: TokenUsagePreferences
    @ObservedObject var manager: TokenUsageManager
    var balanceManager: DeepSeekBalanceManager? = nil
    var credentialConfiguredProviders: Set<TokenUsageProvider> = []
    let strings: Strings
    var onOpenSettings: (() -> Void)? = nil
    @State private var draggingId: TokenUsageProvider?

    private var configuredProviders: [TokenUsageProvider] {
        TokenUsageProviderDisplayPolicy.providers(
            providerOrder: preferences.configuration.providerOrder,
            configuredLimitProviders: Set(manager.configuredProviders),
            credentialConfiguredProviders: credentialConfiguredProviders,
            showingDeepSeekBalance: balanceManager?.showingBalanceCard ?? false,
            hiddenProviders: []
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(strings.tokenSettingsLimitsDisplay)
                .font(.system(.headline, design: .default))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            toggleRow(
                strings.tokenSettingsLimitsRemaining,
                isOn: Binding(
                    get: { preferences.configuration.limitsDisplayMode == .remaining },
                    set: { isRemaining in
                        preferences.update {
                            $0.limitsDisplayMode = isRemaining ? .remaining : .used
                        }
                    }
                )
            )
            .accessibilityIdentifier(SettingsAccessibilityID.tokenUsagePopoverDisplayMode.rawValue)

            toggleRow(strings.tokenResetToastLabel, isOn: Binding(
                get: { preferences.configuration.resetToastEnabled },
                set: { preferences.setResetToastEnabled($0) }
            ))
            .accessibilityIdentifier(SettingsAccessibilityID.tokenUsagePopoverResetToast.rawValue)

            toggleRow(strings.tokenResetConfettiLabel, isOn: Binding(
                get: { preferences.configuration.resetConfettiEnabled },
                set: { preferences.setResetConfettiEnabled($0) }
            ))
            .accessibilityIdentifier(SettingsAccessibilityID.tokenUsagePopoverResetConfetti.rawValue)

            Divider()
                .opacity(0.35)
                .padding(.bottom, 2)

            VStack(spacing: 0) {
                ForEach(configuredProviders) { provider in
                    providerRow(provider)
                        .opacity(draggingId == provider ? 0.4 : 1)
                        .onDrag {
                            draggingId = provider
                            return NSItemProvider(object: provider.rawValue as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: TokenUsageProviderReorderDropDelegate(
                                target: provider,
                                configuredOrder: { configuredProviders },
                                preferences: preferences,
                                draggingId: $draggingId
                            )
                        )
                }
            }
            .padding(.bottom, 6)

            if let onOpenSettings {
                Divider()
                    .opacity(0.35)

                Button {
                    onOpenSettings()
                } label: {
                    HStack(spacing: 6) {
                        Text(strings.tokenSettingsManageMoreProviders)
                            .font(.system(.caption, design: .default))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(SettingsAccessibilityID.tokenUsagePopoverManageMore.rawValue)
            }
        }
        .frame(width: 240)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(.body, design: .default))
                .foregroundStyle(.primary)
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func providerRow(_ provider: TokenUsageProvider) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)

            TokenUsageProviderIconView(provider: provider, size: 16, cornerRadius: 4)

            Text(provider.displayName)
                .font(.system(.body, design: .default))

            Spacer()

            Toggle("", isOn: Binding(
                get: { !preferences.configuration.hiddenProviders.contains(provider) },
                set: { visible in preferences.setProviderHidden(provider, hidden: !visible) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .accessibilityIdentifier(SettingsAccessibilityID.tokenUsageProviderVisible(provider))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.openHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - 平滑拖拽排序

private struct TokenUsageProviderReorderDropDelegate: DropDelegate {
    let target: TokenUsageProvider
    let configuredOrder: () -> [TokenUsageProvider]
    let preferences: TokenUsagePreferences
    @Binding var draggingId: TokenUsageProvider?

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingId,
              dragging != target else { return }
        let order = configuredOrder()
        guard let from = order.firstIndex(of: dragging),
              let to = order.firstIndex(of: target) else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            preferences.moveConfiguredProviders(
                from: IndexSet(integer: from),
                to: to > from ? to + 1 : to,
                configured: Set(order)
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        return true
    }

    func dropExited(info: DropInfo) {}

    func validateDrop(info: DropInfo) -> Bool { true }
}
