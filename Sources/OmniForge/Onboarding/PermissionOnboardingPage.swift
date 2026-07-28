import SwiftUI

/// Onboarding 第二步：权限请求页 — 引导用户授予 Accessibility 和通知权限。
/// 权限状态通过 Permissions.shared 实时刷新（应用激活时自动 refresh）。
struct PermissionOnboardingPage: View {
    let strings: Strings
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 56, height: 56)
                    Image(systemName: "lock.shield")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Text(strings.onboardingPermissionsTitle)
                    .font(.system(size: 19, weight: .bold))
                Text(strings.onboardingPermissionsBody)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 48)
            }
            .padding(.top, 30)

            VStack(spacing: 0) {
                permissionRow(
                    icon: "accessibility",
                    title: strings.onboardingPermissionAccessibility,
                    description: strings.onboardingPermissionAccessibilityDescription,
                    granted: permissions.accessibility,
                    onRequest: requestAccessibility
                )

                Divider().padding(.vertical, 8)

                permissionRow(
                    icon: "bell",
                    title: strings.onboardingPermissionNotifications,
                    description: strings.onboardingPermissionNotificationsDescription,
                    granted: permissions.notifications,
                    onRequest: requestNotifications
                )
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .padding(.horizontal, 28)

            Button {
                permissions.refresh()
            } label: {
                Label(strings.onboardingRecheck, systemImage: "arrow.clockwise")
            }
            .controlSize(.small)

            Text(strings.onboardingPermissionHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)

            Spacer()
        }
    }

    @ViewBuilder
    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        granted: Bool,
        onRequest: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(granted ? .green : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
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
    }

    private func requestAccessibility() {
        _ = permissions.requestAccessibility()
    }

    private func requestNotifications() {
        permissions.requestNotifications()
    }
}
