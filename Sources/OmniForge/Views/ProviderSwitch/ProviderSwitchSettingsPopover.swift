import SwiftUI

/// 供应商页齿轮弹层（对齐 Token「限额显示」弹层模式）：
/// 收纳原底部链接的三个动作——新增供应商（仅菜单栏场景，设置窗口顶部
/// 已有大按钮不重复）、编辑配置文件、恢复备份。动作行对齐 Token 弹层
/// 主体行规格（body 主色文字 + 紧凑行距，chevron 表跳转），动作目标
/// tool 由宿主按 displayedTool 快照注入。
struct ProviderSwitchSettingsPopover: View {
    let strings: Strings
    /// 是否展示「新增供应商」动作（菜单栏场景；设置窗口走顶部主按钮）。
    var showsAddProviderAction = false
    var onAddProvider: (() -> Void)? = nil
    let onEditConfigFile: () -> Void
    let onRestoreBackup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(strings.providerSettingsPopoverTitle)
                .font(.system(.headline, design: .default))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            if showsAddProviderAction, let onAddProvider {
                actionRow(
                    title: strings.providerAddProvider,
                    accessibilityID: SettingsAccessibilityID.providerSwitchPopoverAddProvider.rawValue
                ) {
                    onAddProvider()
                }
            }

            actionRow(
                title: strings.providerEditConfigFile,
                accessibilityID: SettingsAccessibilityID.providerSwitchPopoverEditConfig.rawValue
            ) {
                onEditConfigFile()
            }

            actionRow(
                title: strings.providerRestoreBackup,
                accessibilityID: SettingsAccessibilityID.providerSwitchPopoverRestoreBackup.rawValue
            ) {
                onRestoreBackup()
            }
        }
        .padding(.bottom, 6)
        .frame(width: 240)
    }

    /// 主体动作行（对齐 Token 弹层 toggle 行规格：body 主色 + h12/v6 紧凑密度；
    /// 右侧 chevron 沿用 Token 弹层「管理更多提供商」的 9pt 次要箭头，表跳转动作）。
    private func actionRow(
        title: String,
        accessibilityID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(.body, design: .default))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
    }
}
