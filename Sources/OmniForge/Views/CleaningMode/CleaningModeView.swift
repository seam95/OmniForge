import SwiftUI

/// 清洁模式详情页（实用工具 compact 布局，平面分区）：
/// 双动作平铺行 / 运行中状态 + 退出 / 设置（遮罩颜色胶囊、超时开关+档位）/ 权限引导横幅。
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
        // 外层控制中心已提供 ScrollView；平面拼装由宿主承载滚动。
        VStack(spacing: 0) {
            if !permissions.accessibility {
                permissionSection
            } else {
                if case .active(let mode) = manager.state {
                    activeSection(mode: mode)
                } else {
                    actionRows
                }

                FlatHairline()

                settingsSection
            }
        }
    }

    // MARK: - 动作区（idle）

    /// 页面唯一主动作：两个平铺行（徽章 + 标题 + 说明），整行 hover 可点。
    private var actionRows: some View {
        VStack(spacing: 0) {
            actionRow(
                title: strings.cleaningModeActionKeyboard,
                hint: strings.cleaningModeActionKeyboardHint,
                symbol: "keyboard"
            ) {
                manager.start(.keyboard)
            }

            Rectangle()
                .fill(colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08))
                .frame(height: 1)

            actionRow(
                title: strings.cleaningModeActionScreen,
                hint: strings.cleaningModeActionScreenHint,
                symbol: "display"
            ) {
                manager.start(.screen)
            }
        }
    }

    private func actionRow(title: String, hint: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(tint.opacity(colorScheme == .dark ? 0.22 : 0.14))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Stats.font13SemiBold)
                        .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                    Text(hint)
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(FlatHoverButtonStyle())
    }

    // MARK: - 运行中（active）

    private func activeSection(mode: CleaningMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.Stats.statusNormal)
                    .frame(width: 6, height: 6)
                Text(mode == .keyboard ? strings.cleaningModeActiveKeyboard : strings.cleaningModeActiveScreen)
                    .font(Theme.Stats.font13SemiBold)
                    .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
            }

            if let since = manager.activeSince {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    // 大数字语言：28 semibold 等宽数字
                    Text(Self.elapsedText(since: since))
                        .font(.system(size: 28, weight: .semibold).monospacedDigit())
                        .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                }
            }

            Button {
                manager.stop()
            } label: {
                Text(strings.cleaningModeExit)
                    .font(Theme.Stats.font13SemiBold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Stats.up)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 权限引导

    /// 辅助功能未授权：tint 横幅引导而非静默失败（SPEC §4.2）。
    private var permissionSection: some View {
        PanelTintBanner(
            icon: "lock.shield",
            tint: tint,
            title: strings.cleaningModePermissionTitle
        ) {
            Button(strings.cleaningModePermissionAction) {
                Permissions.shared.openAccessibilitySettings()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 设置区

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlatSectionHeader(title: strings.cleaningModeOverlayStyle, accent: tint)

            HStack(spacing: 10) {
                styleCapsule(style: .black, swatch: Color.black)
                styleCapsule(style: .white, swatch: Color.white)
            }

            Rectangle()
                .fill(colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08))
                .frame(height: 1)

            Toggle(strings.cleaningModeTimeout, isOn: Binding(
                get: { manager.timeout != .off },
                set: { enabled in
                    manager.timeout = enabled
                        ? (manager.timeout == .off ? CleaningTimeout.standard : manager.timeout)
                        : .off
                }
            ))
            .toggleStyle(.switch)
            .font(Theme.Stats.font12Medium)

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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                    .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
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

/// 平铺行按钮：hover 浅灰圆角底（对齐 `MonitorTappableSection` 的 hoverFill 语言）。
struct FlatHoverButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                isHovered ? MonitorOverviewPalette.hoverFill(colorScheme) : Color.clear
            )
            .onHover { hovering in
                withAnimation(Theme.Animation.hover) {
                    isHovered = hovering
                }
            }
    }
}
