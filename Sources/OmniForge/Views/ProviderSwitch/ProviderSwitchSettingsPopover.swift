import SwiftUI

/// 供应商页齿轮弹层（对齐 Token「限额显示」弹层模式）：
/// 收纳原底部链接的三个动作——新增供应商（仅菜单栏场景，设置窗口顶部
/// 已有大按钮不重复）、编辑配置文件、恢复备份。动作行对齐 Token 弹层
/// 主体行规格（body 主色文字 + 紧凑行距），动作目标 tool 由宿主按
/// displayedTool 快照注入。
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
                    title: strings.providerAddProviderAction,
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
        // 宽度贴合内容（由最宽一行决定：中文约 100pt / 英文约 136pt），
        // 不照搬 Token 弹层 240pt 固定宽——那边每行含 logo 与开关需要横向空间，
        // 此处为纯文字动作列表，固定宽会留下过半空白。
        .fixedSize(horizontal: true, vertical: false)
    }

    /// 主体动作行（对齐 Token 弹层 toggle 行规格：body 主色 + h12/v6 紧凑密度；
    /// 纯动作列表，右侧不加跳转箭头）。
    private func actionRow(
        title: String,
        accessibilityID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.body, design: .default))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
    }
}
