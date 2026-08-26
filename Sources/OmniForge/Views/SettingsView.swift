import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var navigation: SettingsNavigationModel
    @ObservedObject private var runtime = FeatureRuntime.shared
    /// 固定显示侧栏，避免切换到非 Form 全页 detail（清理/卸载）时系统自动收起 primary 列。
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    init(
        state: AppState,
        navigation: SettingsNavigationModel? = nil,
        useScrollContainer: Bool = true
    ) {
        self.state = state
        self.navigation = navigation ?? SettingsNavigationModel()
        // 保留参数以兼容 EmbeddedSettingsView；侧边栏外壳自身处理滚动。
        _ = useScrollContainer
    }

    var body: some View {
        let visibleTabs = SettingsToolbarTab.visibleCases(isAvailable: runtime.isAvailable)
        let visibleSections = SettingsToolbarTab.visibleSections(isAvailable: runtime.isAvailable)

        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $navigation.selectedTab) {
                ForEach(visibleTabs.filter { $0.sidebarGroup == nil }) { tab in
                    Label(tab.title(in: state.l10n.s), systemImage: tab.systemImage)
                        .tag(tab)
                }

                ForEach(visibleSections) { section in
                    Section(section.title(in: state.l10n.s)) {
                        ForEach(section.tabs) { tab in
                            Label(tab.title(in: state.l10n.s), systemImage: tab.systemImage)
                                .tag(tab)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail(for: navigation.selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, idealWidth: 820, minHeight: 480, idealHeight: 560)
        // detail 切到非 Form 全页（清理/卸载）时，系统会通过双向 binding 自动折叠 primary 列；
        // 切换后强制还原侧栏全显，抵消该回写。
        .onChange(of: navigation.selectedTab) { _, _ in
            columnVisibility = .all
        }
        .onChange(of: runtime.revision) { _, _ in
            navigation.select(navigation.selectedTab, isAvailable: runtime.isAvailable)
        }
    }

    @ViewBuilder
    private func detail(for tab: SettingsToolbarTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsView(state: state)
                .navigationTitle(tab.title(in: state.l10n.s))
        case .inputMethod:
            InputMethodSettingsView(state: state)
                .navigationTitle(tab.title(in: state.l10n.s))
        case .clipboard:
            ClipboardSettingsView(state: state)
                .navigationTitle(tab.title(in: state.l10n.s))
        case .shelf:
            ShelfSettingsView(state: state)
                .navigationTitle(tab.title(in: state.l10n.s))
        case .screenshot:
            ScreenshotSettingsView(state: state)
                .navigationTitle(tab.title(in: state.l10n.s))
        case .mouse:
            MouseSettingsView(state: state)
                .navigationTitle(tab.title(in: state.l10n.s))
        case .performance:
            PerformanceSettingsView(state: state)
                .navigationTitle(tab.title(in: state.l10n.s))
        case .tokenUsage:
            TokenUsageSettingsView(state: state)
                .navigationTitle(tab.title(in: state.l10n.s))
        case .keepAwake:
            KeepAwakeSettingsView(state: state)
                .navigationTitle(tab.title(in: state.l10n.s))
        case .providerSwitch:
            if let manager = state.providerSwitchManager {
                ProviderSwitchSettingsView(
                    manager: manager,
                    strings: state.l10n.s
                )
                .navigationTitle(tab.title(in: state.l10n.s))
            }
        case .cleaner:
            CleanerView(strings: state.l10n.s)
                .navigationTitle(tab.title(in: state.l10n.s))
        case .uninstaller:
            UninstallerView(strings: state.l10n.s)
                .navigationTitle(tab.title(in: state.l10n.s))
        case .features:
            FeatureHubView(l10n: state.l10n)
                .navigationTitle(tab.title(in: state.l10n.s))
        }
    }
}
