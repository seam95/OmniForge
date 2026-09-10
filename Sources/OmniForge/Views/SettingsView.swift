import SwiftUI
import KeyboardShortcuts

/// 设置窗口分区切换转场：行为与既有实现完全一致（SPEC §4.1 设置窗口不改动）。
/// PageSwitch 统一模块面向控制中心/浮窗/Tab；设置窗口保留独立实现。
fileprivate extension View {
    func settingsPeerTransition() -> some View {
        transition(
            AnyTransition.opacity.combined(with: .offset(y: 6))
        )
    }
}


struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var navigation: SettingsNavigationModel
    @ObservedObject private var runtime = FeatureRuntime.shared
    /// 固定显示侧栏，避免切换到非 Form 全页 detail 时系统自动收起 primary 列。
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    init(
        state: AppState,
        navigation: SettingsNavigationModel? = nil
    ) {
        self.state = state
        self.navigation = navigation ?? SettingsNavigationModel()
    }

    var body: some View {
        let visibleTabs = SettingsToolbarTab.visibleCases(isAvailable: runtime.isAvailable)
        let visibleSections = SettingsToolbarTab.visibleSections(isAvailable: runtime.isAvailable)

        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $navigation.selectedTab) {
                ForEach(visibleTabs.filter { $0.sidebarGroup == nil }) { tab in
                    sidebarRow(for: tab)
                }

                ForEach(visibleSections) { section in
                    Section(section.title(in: state.l10n.s)) {
                        ForEach(section.tabs) { tab in
                            sidebarRow(for: tab)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            // detail 各分区整页切换：peer 淡切与控制中心/主浮窗 tab 手感对齐，
            // ZStack 让新旧分区在转场期间叠放。
            ZStack {
                detail(for: navigation.selectedTab)
                    .settingsPeerTransition()
            }
            .animation(Theme.Animation.pageTransition, value: navigation.selectedTab)
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
        .toolbar {
            SettingsToolbarReservation.item
        }
        .omniNoFocusRing()
    }

    /// 侧栏行：彩色圆角徽章图标 + 标题（系统设置风格，选中态徽章保持彩色可读）。
    private func sidebarRow(for tab: SettingsToolbarTab) -> some View {
        Label {
            Text(tab.title(in: state.l10n.s))
        } icon: {
            Image(systemName: tab.systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(tab.sidebarTint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .tag(tab)
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
        case .promptOptimizer:
            PromptOptimizerSettingsView(state: state)
                .navigationTitle(tab.title(in: state.l10n.s))
        case .features:
            FeatureHubView(l10n: state.l10n)
                .navigationTitle(tab.title(in: state.l10n.s))
        }
    }
}

/// 设置窗口工具栏的恒定占位。
///
/// SwiftUI 在工具栏**一个 item 都没有**时会把整个工具栏移除，标题栏高度随之从
/// 52pt 掉到 28pt。特性页的「全部安装 / 全部卸载」只在该页存在，于是切到其他
/// 页面时标题栏会跳变 24pt（内容区反向跳变，视觉上像整页位移）。
///
/// 这里在窗口根层放置一个**不可见的 1pt item**：工具栏因此在所有设置页恒定存在，
/// 标题栏高度稳定；各页面自己的工具栏按钮（如特性页的批量操作）照常并入，
/// 显示与交互逻辑不受影响。
enum SettingsToolbarReservation {
    /// 占位不参与视觉效果，仅用于让工具栏保持存在。
    static let placeholderSize: CGFloat = 1

    @ToolbarContentBuilder
    static var item: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Color.clear
                .frame(width: placeholderSize, height: placeholderSize)
                .accessibilityHidden(true)
        }
    }
}
