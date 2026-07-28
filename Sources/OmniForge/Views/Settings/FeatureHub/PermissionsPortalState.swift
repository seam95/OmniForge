import Foundation

/// 权限面板中单个特性对某权限的展示条目。
struct PermissionFeatureUsageEntry: Equatable, Identifiable {
    var id: String { "\(feature.rawValue)-\(usage.rawValue)" }
    let feature: AppFeature
    let usage: FeaturePermissionUsage
}

/// 权限面板状态构建：区分 required/configured/optional/inactive。
enum PermissionsPortalState {
    static func signatureDiagnostic(_ summary: PermissionSignatureSummary) -> String {
        [summary.kind.rawValue, summary.identifier, summary.teamIdentifier]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// 为指定权限生成已安装特性的用途列表。
    /// - Parameters:
    ///   - permission: 目标权限
    ///   - isAvailable: Feature availability 查询
    ///   - mouseJiggleEnabled: 保持唤醒指针微动偏好；仅影响 accessibility 的 configured/inactive
    static func usageEntries(
        for permission: AppPermission,
        isAvailable: (AppFeature) -> Bool,
        mouseJiggleEnabled: Bool = false
    ) -> [PermissionFeatureUsageEntry] {
        AppFeature.allCases.compactMap { feature in
            guard isAvailable(feature) else { return nil }
            guard let usage = feature.permissionUsage(
                for: permission,
                mouseJiggleEnabled: mouseJiggleEnabled
            ) else {
                return nil
            }
            // inactive 仍展示：用户需看到“声明了但当前未使用”。
            return PermissionFeatureUsageEntry(feature: feature, usage: usage)
        }
    }

    /// 本地化用途标签。
    static func usageLabel(_ usage: FeaturePermissionUsage, strings: Strings) -> String {
        switch usage {
        case .required: return strings.featureHubPermUsageRequired
        case .configured: return strings.featureHubPermUsageConfigured
        case .optional: return strings.featureHubPermUsageOptional
        case .inactive: return strings.featureHubPermUsageInactive
        }
    }

    /// 权限是否已授予（测试与 View 共用映射，避免重复 switch）。
    @MainActor
    static func isPermissionGranted(
        _ permission: AppPermission,
        permissions: Permissions
    ) -> Bool {
        switch permission {
        case .accessibility: return permissions.accessibility
        case .inputMonitoring: return permissions.inputMonitoring
        case .notifications: return permissions.notifications
        case .fullDiskAccess: return permissions.fullDiskAccess
        case .screenRecording: return permissions.screenRecording
        }
    }
}
