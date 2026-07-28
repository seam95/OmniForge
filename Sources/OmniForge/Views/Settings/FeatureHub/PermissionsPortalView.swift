import SwiftUI

/// 权限透明度面板 — 每个权限一个 Section，贴合 grouped Form。
struct PermissionsPortalView: View {
    @ObservedObject var runtime: FeatureRuntime
    @ObservedObject var permissions = Permissions.shared
    let strings: Strings
    /// 保持唤醒指针微动偏好；用于 accessibility 的 configured/inactive 展示。
    var mouseJiggleEnabled: Bool = false

    var body: some View {
        Section {
            HStack {
                Button(strings.featureHubPermRefresh) {
                    permissions.refresh()
                }
                Spacer()
                Text("\(strings.featureHubPermSignature)：\(PermissionsPortalState.signatureDiagnostic(permissions.signatureSummary))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }

        ForEach(AppPermission.allCases, id: \.rawValue) { perm in
            permissionSection(perm)
        }
    }

    @ViewBuilder
    private func permissionSection(_ perm: AppPermission) -> some View {
        let isGranted = isPermissionGranted(perm)
        let usageEntries = PermissionsPortalState.usageEntries(
            for: perm,
            isAvailable: { runtime.isAvailable($0) },
            mouseJiggleEnabled: mouseJiggleEnabled
        )

        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: perm.symbolName)
                    .font(.system(size: 16))
                    .foregroundStyle(isGranted ? Color.accentColor : .secondary)
                    .frame(width: 22)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(perm.hubName(in: strings))
                        .font(.body)

                    Text(perm.hubDescription(in: strings))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !isGranted, perm == .accessibility || perm == .inputMonitoring {
                        Text(strings.featureHubPermRecoveryHint)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if usageEntries.isEmpty {
                        Text(strings.featureHubPermUsedByNone)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(strings.featureHubPermUsedBy)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            ForEach(usageEntries) { entry in
                                HStack(spacing: 6) {
                                    Text(entry.feature.hubName(in: strings))
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.12), in: Capsule())
                                    Text(PermissionsPortalState.usageLabel(entry.usage, strings: strings))
                                        .font(.caption2)
                                        .foregroundStyle(usageColor(entry.usage))
                                }
                            }
                        }
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(isGranted ? strings.featureHubPermStatusGranted : strings.featureHubPermStatusMissing)
                        .font(.caption)
                        .foregroundStyle(isGranted ? .green : .orange)

                    if !isGranted {
                        Button(strings.settingsGrantAccess) {
                            permissions.requestAccess(for: perm)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private func usageColor(_ usage: FeaturePermissionUsage) -> Color {
        switch usage {
        case .required: return .primary
        case .configured: return .accentColor
        case .optional: return .secondary
        case .inactive: return Color.secondary.opacity(0.7)
        }
    }

    private func isPermissionGranted(_ perm: AppPermission) -> Bool {
        PermissionsPortalState.isPermissionGranted(perm, permissions: permissions)
    }
}
