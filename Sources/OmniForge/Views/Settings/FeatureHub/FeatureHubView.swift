import SwiftUI

/// Feature Hub — 权限与会话状态；功能开关已下沉到各设置页。
struct FeatureHubView: View {
    @ObservedObject var runtime = FeatureRuntime.shared
    @ObservedObject var l10n: L10n
    @ObservedObject private var cleaner = JunkCleaner.shared
    @ObservedObject private var uninstaller = AppUninstaller.shared

    @State private var tab: HubTab = .overview

    private enum HubTab {
        case overview, permissions
    }

    private var strings: Strings { l10n.s }

    private var uninstallGuard: UtilityUninstallGuard {
        UtilityUninstallGuard(
            cleanerIsBusy: cleaner.isBusy,
            uninstallerIsBusy: uninstaller.isBusy
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("", selection: $tab) {
                    Text(strings.featureHubTabFeatures)
                        .tag(HubTab.overview)
                    Text(strings.featureHubTabPermissions)
                        .tag(HubTab.permissions)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } footer: {
                // 仅权限页需要分段说明；特性页说明合并到工具条下方，避免重复长文案
                if tab == .permissions {
                    Text(strings.featureHubPermissionsIntro)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if runtime.needsRestartToUnload {
                Section {
                    FeatureRestartBanner(runtime: runtime, strings: strings)
                }
            }

            if tab == .overview {
                overviewSections
            } else {
                PermissionsPortalView(runtime: runtime, strings: strings)
            }
        }
        .settingsPageStyle()
        // 批量操作常驻窗口工具栏：长列表滚动到任意位置都能触达，
        // 不再需要滚回顶部（特性页内容约 3.4 屏）。
        .toolbar {
            if tab == .overview {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(strings.featureHubInstallAll) {
                        Task { @MainActor in
                            for feature in AppFeature.allCases {
                                _ = await runtime.setAvailableAsync(feature, true)
                            }
                        }
                    }
                    .disabled(runtime.availableCount == AppFeature.allCases.count)

                    Button(strings.featureHubUninstallAll) {
                        Task { @MainActor in
                            for feature in AppFeature.allCases
                            where uninstallGuard.canSetAvailability(of: feature, to: false) {
                                _ = await runtime.setAvailableAsync(feature, false)
                            }
                        }
                    }
                    .disabled(runtime.availableCount == 0 || !uninstallGuard.canUninstallAll)
                }
            }
        }
    }

    @ViewBuilder
    private var overviewSections: some View {
        // 计数留在页内顶部；批量安装/卸载已上移到窗口工具栏（滚动时始终可达）。
        Section {
            HStack {
                Text(String(format: strings.featureHubActiveCount,
                            runtime.availableCount, AppFeature.allCases.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if !uninstallGuard.canUninstallAll {
                Text(strings.utilityUninstallBusy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(strings.featureHubIntro)
                .fixedSize(horizontal: false, vertical: true)
        }

        // 安装/卸载开关：真正创建或释放 Manager
        ForEach(FeatureGroup.allCases, id: \.rawValue) { group in
            let features = FeatureGroup.features(in: group)
            if !features.isEmpty {
                Section(group.hubTitle(in: strings)) {
                    ForEach(features, id: \.rawValue) { feature in
                        FeatureRow(
                            feature: feature,
                            runtime: runtime,
                            strings: strings,
                            uninstallGuard: uninstallGuard
                        )
                    }
                }
            }
        }
    }
}
