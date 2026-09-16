import SwiftUI

/// Onboarding 第四步：菜单栏定锚与启航 — 指引菜单栏位置，提供 Dock 图标偏好与开机自启
struct MenubarAnchoringOnboardingPage: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    let strings: Strings

    var body: some View {
        VStack(spacing: 20) {
            // 菜单栏图示与视觉指引
            VStack(spacing: 12) {
                menubarMockup

                VStack(spacing: 6) {
                    Text(strings.onboardingMenubarTitle)
                        .font(.system(size: 20, weight: .bold))

                    Text(strings.onboardingMenubarSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                }
            }
            .padding(.top, 16)

            // 贴心偏好设置卡片
            VStack(spacing: 14) {
                // Dock 图标选项
                Toggle(isOn: $coordinator.retainDockIcon) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(strings.onboardingOptionRetainDock)
                            .font(.system(size: 13, weight: .medium))
                        Text(strings.onboardingOptionRetainDockDesc)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                Divider()

                // 开机自启选项
                Toggle(isOn: $coordinator.launchAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(strings.onboardingOptionLaunchAtLogin)
                            .font(.system(size: 13, weight: .medium))
                        Text(strings.onboardingFeatureLaunchAtLoginDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 36)

            // 握手温馨提示
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 12))
                Text("完成向导后，OmniForge 将自动在右上角为您展开控制中心")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 模拟 macOS 菜单栏与右上角 OmniForge 定位
    private var menubarMockup: some View {
        HStack(spacing: 12) {
            // 左侧模拟 Apple Logo & 菜单
            Image(systemName: "apple.logo")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("OmniForge")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            Text("文件")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text("编辑")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer()

            // 右侧系统图标与 OmniForge 高亮图标
            Image(systemName: "wifi")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Image(systemName: "battery.100")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            // 高亮展示 OmniForge 菜单栏入口
            HStack(spacing: 4) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.accentColor)
                    .shadow(color: Color.accentColor.opacity(0.4), radius: 4, x: 0, y: 1)
            )

            Text("9:41")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.8)
        )
        .padding(.horizontal, 36)
    }
}
