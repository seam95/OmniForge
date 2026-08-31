import SwiftUI

/// 清洁模式详情页（实用工具 compact 布局，SPEC §4.2）：
/// 并排双动作大卡 / 运行中状态 + 退出 / 设置（遮罩颜色色块选择、超时开关+档位）/ 权限引导。
@MainActor
struct CleaningModeView: View {
    let strings: Strings
    /// 详情页仅在功能可用时可达，正常非 nil；防御式留空态。
    private let manager: CleaningModeManager?

    init(strings: Strings, manager: CleaningModeManager? = nil) {
        self.strings = strings
        self.manager = manager
            ?? FeatureRuntime.shared.manager(for: .cleaningMode, as: CleaningModeManager.self)
    }

    var body: some View {
        if let manager {
            CleaningModeContent(strings: strings, manager: manager)
        } else {
            ContentUnavailableView(strings.featureHubNameCleaningMode, systemImage: "bubbles.and.sparkles")
                .padding(.vertical, 24)
        }
    }
}

@MainActor
private struct CleaningModeContent: View {
    let strings: Strings
    @ObservedObject var manager: CleaningModeManager
    @ObservedObject private var permissions = Permissions.shared
    @Environment(\.colorScheme) private var colorScheme

    private var tint: Color { UtilityTool.cleaningMode.tintColor }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if permissions.accessibility {
                    if case .active(let mode) = manager.state {
                        activeCard(mode: mode)
                    } else {
                        actionCards
                    }
                    settingsCard
                } else {
                    permissionCard
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: - 动作区（idle）

    /// 页面唯一主动作：并排双大卡，图标徽章 + 标题 + 说明。
    private var actionCards: some View {
        HStack(spacing: 10) {
            actionCard(
                title: strings.cleaningModeActionKeyboard,
                hint: strings.cleaningModeActionKeyboardHint,
                symbol: "keyboard"
            ) {
                manager.start(.keyboard)
            }
            actionCard(
                title: strings.cleaningModeActionScreen,
                hint: strings.cleaningModeActionScreenHint,
                symbol: "display"
            ) {
                manager.start(.screen)
            }
        }
    }

    private func actionCard(title: String, hint: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(tint.opacity(colorScheme == .dark ? 0.22 : 0.14))
                    )
                Text(title)
                    .font(Theme.Stats.font13SemiBold)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                Text(hint)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 10)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(CleaningCardBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - 运行中（active）

    private func activeCard(mode: CleaningMode) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.Stats.statusNormal)
                    .frame(width: 6, height: 6)
                Text(mode == .keyboard ? strings.cleaningModeActiveKeyboard : strings.cleaningModeActiveScreen)
                    .font(Theme.Stats.font13SemiBold)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
            }

            if let since = manager.activeSince {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Self.elapsedText(since: since))
                        .font(Theme.Stats.font24Bold.monospacedDigit())
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                }
            }

            Button {
                manager.stop()
            } label: {
                Text(strings.cleaningModeExit)
                    .font(Theme.Stats.font13SemiBold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.95, green: 0.35, blue: 0.32))
            )
        }
        .padding(12)
        .background(CleaningCardBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 权限引导

    /// 辅助功能未授权：给出引导而非静默失败（SPEC §4.2）。
    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(strings.cleaningModePermissionTitle)
                .font(Theme.Stats.font13SemiBold)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Permissions.shared.openAccessibilitySettings()
            } label: {
                Text(strings.cleaningModePermissionAction)
                    .font(Theme.Stats.font13SemiBold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor)
            )
        }
        .padding(12)
        .background(CleaningCardBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 设置区

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsTitle(strings.cleaningModeOverlayStyle)
            HStack(spacing: 10) {
                styleCapsule(style: .black, swatch: Color.black)
                styleCapsule(style: .white, swatch: Color.white)
            }

            Divider()
                .padding(.vertical, 2)

            Toggle(strings.cleaningModeTimeout, isOn: Binding(
                get: { manager.timeout != .off },
                set: { enabled in
                    manager.timeout = enabled
                        ? (manager.timeout == .off ? CleaningTimeout.standard : manager.timeout)
                        : .off
                }
            ))
            .toggleStyle(.switch)
            .font(Theme.Stats.font13SemiBold)

            if manager.timeout != .off {
                Picker(strings.cleaningModeTimeout, selection: Binding(
                    get: { manager.timeout },
                    set: { manager.timeout = $0 }
                )) {
                    ForEach(CleaningTimeout.minuteChoices, id: \.self) { choice in
                        Text(choiceLabel(choice)).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(12)
        .background(CleaningCardBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 遮罩颜色选择：色块示意 + 文字，选中态用主题色描边（比纯文字 segmented 直观）。
    private func styleCapsule(style: CleaningOverlayStyle, swatch: Color) -> some View {
        let isSelected = manager.overlayStyle == style
        return Button {
            manager.overlayStyle = style
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(swatch)
                    .frame(width: 14, height: 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    )
                Text(style == .black ? strings.cleaningModeOverlayBlack : strings.cleaningModeOverlayWhite)
                    .font(Theme.Stats.font12Medium)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? tint.opacity(colorScheme == .dark ? 0.22 : 0.12) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? tint : Color.clear, lineWidth: 1)
        )
    }

    private func settingsTitle(_ title: String) -> some View {
        Text(title)
            .font(Theme.Stats.font11Regular.weight(.semibold))
            .foregroundStyle(Color.secondary)
    }

    private func choiceLabel(_ choice: CleaningTimeout) -> String {
        guard case .minutes(let value) = choice else { return strings.cleaningModeTimeoutOff }
        return String(format: strings.cleaningModeTimeoutMinutesFormat, value)
    }

    /// 已持续时长（TimelineView 驱动每秒重绘）。
    private static func elapsedText(since: Date) -> String {
        let interval = Int(Date().timeIntervalSince(since))
        let minutes = interval / 60
        return minutes < 1
            ? String(format: "0:%02d", interval)
            : String(format: "%d:%02d", minutes, interval % 60)
    }
}

/// 卡片底色：浅色用设计系统卡片白，深色用白色低透明度（对齐实用工具列表卡）。
private struct CleaningCardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if colorScheme == .dark {
                Color.white.opacity(0.08)
            } else {
                Theme.Stats.cardBackground
            }
        }
    }
}
