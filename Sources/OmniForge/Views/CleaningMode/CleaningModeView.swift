import SwiftUI

/// 清洁模式详情页（实用工具 compact 布局，SPEC §4.2）：
/// 双动作按钮 / 运行中状态 + 退出 / 内嵌设置（遮罩颜色、超时兜底）/ 辅助功能权限引导。
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if permissions.accessibility {
                    actionsCard
                    settingsCard
                } else {
                    permissionCard
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: - 区块

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: UtilityTool.cleaningMode.symbolName())
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(UtilityTool.cleaningMode.tintColor)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(UtilityTool.cleaningMode.tintColor.opacity(0.16))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(strings.featureHubNameCleaningMode)
                    .font(Theme.Stats.font13SemiBold)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                Text(strings.utilityCleaningModeSubtitle)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    /// idle：两个动作；active：状态 + 退出（SPEC D14 次路径）。
    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .active(let mode) = manager.state {
                activeHeader(mode: mode)
                exitButton
            } else {
                actionButton(
                    title: strings.cleaningModeActionKeyboard,
                    hint: strings.cleaningModeActionKeyboardHint,
                    symbol: "keyboard"
                ) {
                    manager.start(.keyboard)
                }
                actionButton(
                    title: strings.cleaningModeActionScreen,
                    hint: strings.cleaningModeActionScreenHint,
                    symbol: "rectangle.and.pencil.and.ellipsis"
                ) {
                    manager.start(.screen)
                }
            }
        }
        .padding(12)
        .background(CleaningCardBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func activeHeader(mode: CleaningMode) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.Stats.statusNormal)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(mode == .keyboard ? strings.cleaningModeActiveKeyboard : strings.cleaningModeActiveScreen)
                    .font(Theme.Stats.font13SemiBold)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                if let since = manager.activeSince {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(Self.elapsedText(since: since))
                            .font(Theme.Stats.font11Regular)
                            .foregroundStyle(Color.secondary)
                            .monospacedDigit()
                    }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var exitButton: some View {
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

    private func actionButton(title: String, hint: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(UtilityTool.cleaningMode.tintColor)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(UtilityTool.cleaningMode.tintColor.opacity(0.14))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.Stats.font13SemiBold)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                    Text(hint)
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.white)
        )
    }

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

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsTitle(strings.cleaningModeOverlayStyle)
            Picker(strings.cleaningModeOverlayStyle, selection: Binding(
                get: { manager.overlayStyle },
                set: { manager.overlayStyle = $0 }
            )) {
                Text(strings.cleaningModeOverlayBlack).tag(CleaningOverlayStyle.black)
                Text(strings.cleaningModeOverlayWhite).tag(CleaningOverlayStyle.white)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()

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

    private func settingsTitle(_ title: String) -> some View {
        Text(title)
            .font(Theme.Stats.font11Regular.weight(.semibold))
            .foregroundStyle(Color.secondary)
    }

    private func choiceLabel(_ choice: CleaningTimeout) -> String {
        guard case .minutes(let value) = choice else { return strings.cleaningModeTimeoutOff }
        return String(format: strings.cleaningModeTimeoutMinutesFormat, value)
    }

    /// 已持续时长（秒级刷新交给状态/进度变化驱动的重绘；分钟级展示足够）。
    private static func elapsedText(since: Date) -> String {
        let interval = Int(Date().timeIntervalSince(since))
        let minutes = interval / 60
        return minutes < 1
            ? String(format: "%02ds", interval)
            : String(format: "%dm %02ds", minutes, interval % 60)
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
