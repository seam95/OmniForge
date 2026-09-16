import SwiftUI

/// Onboarding 第三步：透明分级权限 — 区分免权限能力与系统增强权限
struct PermissionOnboardingPage: View {
    let strings: Strings
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        VStack(spacing: 16) {
            // 头部标题与隐私承诺
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: "lock.shield")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                Text(strings.onboardingPermissionsTitle)
                    .font(.system(size: 19, weight: .bold))

                Text(strings.onboardingPrivacyBanner)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            .padding(.top, 14)

            // 绿色卡片：免权限功能公示
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text(strings.onboardingZeroPermissionTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)

                    Text(strings.onboardingZeroPermissionDesc)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.green.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.2), lineWidth: 1)
            )
            .padding(.horizontal, 28)

            // 需授权权限列表
            VStack(spacing: 0) {
                permissionRow(
                    icon: "accessibility",
                    title: strings.onboardingPermissionAccessibility,
                    description: strings.onboardingPermissionAccessibilityDescription,
                    granted: permissions.accessibility,
                    onRequest: { permissions.requestAccess(for: .accessibility) }
                )

                Divider().padding(.vertical, 6)

                permissionRow(
                    icon: "camera.viewfinder",
                    title: strings.onboardingPermissionScreenRecording,
                    description: strings.onboardingPermissionScreenRecordingDescription,
                    granted: permissions.screenRecording,
                    onRequest: { permissions.requestAccess(for: .screenRecording) }
                )

                Divider().padding(.vertical, 6)

                permissionRow(
                    icon: "bell",
                    title: strings.onboardingPermissionNotifications,
                    description: strings.onboardingPermissionNotificationsDescription,
                    granted: permissions.notifications,
                    onRequest: { permissions.requestAccess(for: .notifications) }
                )
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .padding(.horizontal, 28)

            // 底部刷新与跳过提示
            HStack(spacing: 12) {
                Button {
                    permissions.refresh()
                } label: {
                    Label(strings.onboardingRecheck, systemImage: "arrow.clockwise")
                }
                .controlSize(.small)

                Text(strings.onboardingPermissionHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        granted: Bool,
        onRequest: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(granted ? .green : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if granted {
                Label(strings.onboardingPermissionGranted, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button(strings.onboardingGrantPermission, action: onRequest)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 2)
    }
}
