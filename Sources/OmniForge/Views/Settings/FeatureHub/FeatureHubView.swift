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
        // 分段 tab 与性能 / Token 用量页同构：置于页面顶部居中铺满、下接发丝线，
        // 不再嵌进 Form Section（Form 的分组内缩会让 tab 看起来从属于某个分组）。
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(strings.featureHubTabFeatures)
                    .tag(HubTab.overview)
                Text(strings.featureHubTabPermissions)
                    .tag(HubTab.permissions)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(SettingsAccessibilityID.featureHubSegment.rawValue)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            Group {
                if tab == .overview {
                    overviewForm
                } else {
                    permissionsForm
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var overviewForm: some View {
        Form {
            restartBannerSection

            overviewSections
        }
        .settingsPageStyle()
    }

    /// 仅权限页需要分段说明；特性页说明合并到工具条下方，避免重复长文案。
    private var permissionsForm: some View {
        Form {
            restartBannerSection

            Section {
                PermissionsPortalView(runtime: runtime, strings: strings)
            } footer: {
                Text(strings.featureHubPermissionsIntro)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsPageStyle()
    }

    @ViewBuilder
    private var restartBannerSection: some View {
        if runtime.needsRestartToUnload {
            Section {
                FeatureRestartBanner(runtime: runtime, strings: strings)
            }
        }
    }

    @ViewBuilder
    private var overviewSections: some View {
        // 计数 + 批量操作同一行：批量动作属于本页内容，留在页内而不进窗口工具栏
        // （工具栏会让标题栏高度随页面切换变化）。
        Section {
            HStack {
                Text(String(format: strings.featureHubActiveCount,
                            runtime.availableCount, AppFeature.allCases.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
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
            .controlSize(.small)

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
