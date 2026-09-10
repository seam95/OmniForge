import SwiftUI

/// 实用工具内容在设置窗口与 380pt 控制中心中的布局策略。
enum UtilityContentLayout: Equatable {
    case settings
    case compact

    /// 控制中心结果页列表高度。
    /// `List` 嵌在 `AdaptiveHeightScroll` 内不会自报固有高度，会塌成接近 0；compact 必须显式给定。
    static let compactResultsListHeight: CGFloat = 300

    var contentWidth: CGFloat? {
        switch self {
        case .settings: nil
        case .compact: 348
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .settings: 28
        case .compact: 16
        }
    }

    var dropTargetWidth: CGFloat {
        switch self {
        case .settings: 360
        case .compact: 332
        }
    }

    var dropTargetHeight: CGFloat {
        switch self {
        case .settings: 200
        case .compact: 132
        }
    }

    /// 设置页由父级分栏分配高度；控制中心页返回固定列表高度。
    var resultsListHeight: CGFloat? {
        switch self {
        case .settings: nil
        case .compact: Self.compactResultsListHeight
        }
    }
}

extension View {
    /// 紧凑布局给结果 `List` 明确高度，避免嵌套 ScrollView 时列表区域消失。
    @ViewBuilder
    func utilityResultsListHeight(_ layout: UtilityContentLayout) -> some View {
        if let height = layout.resultsListHeight {
            self.frame(height: height)
        } else {
            self
        }
    }
}

/// 实用工具页内部导航：列表 ↔ 详情。由宿主（控制中心容器）持有，
/// 面板切换期间视图销毁重建也不丢失所在层级。
enum UtilityToolsRoute: Equatable {
    case list
    case detail(UtilityTool)
}

enum UtilityToolsPresentation {
    static func resolvedSelection(
        storedRawValue: String,
        visibleTools: [UtilityTool]
    ) -> UtilityTool? {
        UtilityTool.resolvedSelection(UtilityTool(rawValue: storedRawValue), in: visibleTools)
    }

    /// 重新进入本页时的路由决策：仅"单工具且仍停列表层"时直达详情，
    /// 其余情况保留现状（面板切换回来不再弹回列表）。
    static func resolvedReentryRoute(
        current: UtilityToolsRoute,
        visibleTools: [UtilityTool]
    ) -> UtilityToolsRoute {
        guard current == .list, visibleTools.count == 1 else { return current }
        return .detail(visibleTools[0])
    }
}

/// 功能安装管理的破坏性操作门控；运行中的工具只能等待任务完成后卸载。
struct UtilityUninstallGuard: Equatable {
    let cleanerIsBusy: Bool
    let uninstallerIsBusy: Bool

    var canUninstallAll: Bool {
        !cleanerIsBusy && !uninstallerIsBusy
    }

    func isUninstallBlocked(for feature: AppFeature) -> Bool {
        switch feature {
        case .cleaner: cleanerIsBusy
        case .uninstaller: uninstallerIsBusy
        default: false
        }
    }

    func canSetAvailability(of feature: AppFeature, to available: Bool) -> Bool {
        available || !isUninstallBlocked(for: feature)
    }
}

/// 菜单栏“实用工具”页。工具会话由两个进程级服务持有，视图切换不会重置任务。
@MainActor
struct UtilityToolsView: View {
    let strings: Strings
    @ObservedObject var runtime: FeatureRuntime
    @Binding var route: UtilityToolsRoute
    /// 唤醒详情页依赖（信息架构重构阶段②）：会话控制迁入工具页后由宿主注入；
    /// 其余工具不依赖，默认 nil。
    var keepAwakeManager: KeepAwakeManager?
    var clamshellRecoveryCoordinator: ClamshellRecoveryCoordinator?
    var onOpenSettings: (SettingsToolbarTab?) -> Void = { _ in }
    @AppStorage(UserDefaultsKeys.lastUtilityTool) private var storedTool = UtilityTool.cleaner.rawValue

    init(strings: Strings, route: Binding<UtilityToolsRoute>) {
        self.init(strings: strings, route: route, runtime: .shared)
    }

    init(strings: Strings, route: Binding<UtilityToolsRoute>, runtime: FeatureRuntime) {
        self.strings = strings
        self._route = route
        self.runtime = runtime
    }

    /// 控制中心装配：额外注入唤醒详情页依赖（阶段②）。
    init(
        strings: Strings,
        route: Binding<UtilityToolsRoute>,
        runtime: FeatureRuntime = .shared,
        keepAwakeManager: KeepAwakeManager?,
        clamshellRecoveryCoordinator: ClamshellRecoveryCoordinator?,
        onOpenSettings: @escaping (SettingsToolbarTab?) -> Void
    ) {
        self.strings = strings
        self._route = route
        self.runtime = runtime
        self.keepAwakeManager = keepAwakeManager
        self.clamshellRecoveryCoordinator = clamshellRecoveryCoordinator
        self.onOpenSettings = onOpenSettings
    }

    private var visibleTools: [UtilityTool] {
        UtilityTool.visibleCases(isAvailable: runtime.isAvailable)
    }

    private var selectedTool: UtilityTool? {
        UtilityToolsPresentation.resolvedSelection(
            storedRawValue: storedTool,
            visibleTools: visibleTools
        )
    }

    var body: some View {
        // 层级页面统一 Host（SPEC §5/§6）：列表 → 详情为前进，返回为后退，
        // 小幅位移 + 淡出后淡入（4pt/12pt，Reduce Motion 归零）。
        PageSwitchHost(
            requestedRoute: route,
            semantics: { from, to in
                from == .list ? .forward : (to == .list ? .backward : .peer)
            },
            surface: { _ in .clear },
            onRouteMountedBarrier: sizingContext.map { context in
                { route, proceed in
                    context.mountStarted(path: "utility/\(route)", proceed: proceed)
                }
            }
        ) { currentRoute in
            switch currentRoute {
            case .list:
                toolListView
            case .detail(let tool):
                toolDetailView(tool)
            }
        }
        // 宽度拉满；高度由控制中心固定 viewport 承载。
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            repairSelection()
            route = UtilityToolsPresentation.resolvedReentryRoute(
                current: route,
                visibleTools: visibleTools
            )
        }
        .onChange(of: runtime.revision) { _, _ in
            repairSelection()
            // 当前详情的工具被卸载时退回列表，避免渲染不可用工具。
            if case .detail(let tool) = route, !visibleTools.contains(tool) {
                route = .list
            }
        }
    }

    @ViewBuilder
    private var toolListView: some View {
        if visibleTools.isEmpty {
            ContentUnavailableView(
                strings.controlcenterEmpty,
                systemImage: "wrench.and.screwdriver"
            )
            .padding(.vertical, 24)
        } else {
            // 3×3 宫格：固定 380pt 面板下 9 个工具恰好排满三行三列，
            // 新增工具自动进入下一行，由滚动容器承载溢出部分。
            LazyVGrid(columns: UtilityToolGrid.columns, spacing: UtilityToolGrid.spacing) {
                ForEach(visibleTools) { tool in
                    UtilityToolGridItem(tool: tool, strings: strings) {
                        enterDetail(tool)
                    }
                }
            }
            .padding(.horizontal, UtilityToolGrid.horizontalPadding)
            .padding(.vertical, UtilityToolGrid.verticalPadding)
        }
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlCenterSizing) private var sizingContext

    private func enterDetail(_ tool: UtilityTool) {
        storedTool = tool.rawValue
        route = .detail(tool)
    }

    @ViewBuilder
    private func toolDetailView(_ tool: UtilityTool) -> some View {
        VStack(spacing: 0) {
            FlatBackBar(title: tool.hubName(in: strings), backLabel: strings.commonBack) {
                route = .list
            }
            utilityContent(tool)
        }
    }

    @ViewBuilder
    private func utilityContent(_ tool: UtilityTool) -> some View {
        switch tool {
        case .cleaner:
            CleanerContentView(strings: strings, layout: .compact)
        case .uninstaller:
            UninstallerContentView(strings: strings, layout: .compact)
        case .colorPicker:
            ColorPickerContentView(strings: strings, layout: .compact)
        case .networkDiagnostics:
            NetworkDiagnosticsView(strings: strings)
        case .dshWeb:
            DSHWebView(strings: strings)
        case .stickyNotes:
            StickyNotesView(strings: strings)
        case .cleaningMode:
            CleaningModeView(strings: strings)
        case .desktopPet:
            DesktopPetDetailView(strings: strings)
        case .keepAwake:
            KeepAwakeUtilityDetailView(
                manager: keepAwakeManager,
                clamshellRecoveryCoordinator: clamshellRecoveryCoordinator,
                strings: strings,
                isFeatureAvailable: runtime.isAvailable(.keepAwake),
                onOpenSettings: onOpenSettings
            )
        }
    }

    private func repairSelection() {
        guard let repaired = selectedTool else { return }
        if storedTool != repaired.rawValue {
            storedTool = repaired.rawValue
        }
    }
}

/// 宫格布局的几何契约：3 列 × 8pt 间距 × 12pt 外边距，卡片按内容等高。
/// 固定列数保证新增工具进入下一行而不破坏整体排布。
enum UtilityToolGrid {
    /// 列数：380pt 面板下 3 列最规整。
    static let columnCount = 3
    /// 卡片间距（行列一致）。
    static let spacing: CGFloat = 8
    /// 宫格到面板左右边缘的外边距。
    static let horizontalPadding: CGFloat = 16
    /// 宫格到上下内容边缘的外边距。
    static let verticalPadding: CGFloat = 12
    /// 卡片高度：图标徽章 30 + 上下各 12 + 标题行高约 18。
    static let cardHeight: CGFloat = 78

    /// 卡片内容宽度：面板宽 - 两侧外边距 - 列间距后三等分。
    static var cardWidth: CGFloat {
        (ControlCenterContentMetrics.panelWidth - horizontalPadding * 2 - spacing * CGFloat(columnCount - 1))
            / CGFloat(columnCount)
    }

    /// 列定义：等宽、固定 3 列。
    static var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }
}

/// 宫格卡片的视觉状态。
enum UtilityToolCardVisual {
    /// 图标徽章边长，与列表版保持同一尺寸，视觉延续。
    static let iconBadgeSize: CGFloat = 30
    /// 徽章圆角。
    static let iconCornerRadius: CGFloat = 8
    /// 徽章内 SF Symbol 字号。
    static let iconGlyphSize: CGFloat = 14
    /// 卡片圆角，复用 Theme.Radius.card（12pt）。
    static var cardCornerRadius: CGFloat { Theme.Radius.card }
    /// 状态点直径。
    static let statusDotSize: CGFloat = 6
    /// 描述气泡的最大宽度；超出即换行。
    static let hintMaxWidth: CGFloat = 280

    /// 卡片处于「活跃态」：指针悬浮或键盘聚焦，统一驱动高亮与描述显示。
    static func isActive(hovered: Bool, focused: Bool) -> Bool {
        hovered || focused
    }

    /// 气泡停靠边：贴在卡片上方，箭头指向被悬浮的卡片，避免遮挡相邻卡片。
    static let placementEdge: Edge = .top
}

/// 工具行描述气泡：宫格与列表共用同一配方。
/// 宽度按内容贴合（`fixedSize`），超过上限即换行，避免窄面板上溢出屏幕。
struct UtilityToolHintBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Stats.font12Medium)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: UtilityToolCardVisual.hintMaxWidth, alignment: .leading)
            .fixedSize()
            .accessibilityLabel(text)
    }
}

/// 宫格卡片：图标徽章 + 名称 + 状态点，描述以悬浮气泡呈现。
private struct UtilityToolGridItem: View {
    let tool: UtilityTool
    let strings: Strings
    let onTap: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var showsHint = false
    @FocusState private var isFocused: Bool

    private var hintText: String { tool.hubDescription(in: strings) }

    private var isActive: Bool {
        UtilityToolCardVisual.isActive(hovered: isHovered, focused: isFocused)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: UtilityToolCardVisual.iconCornerRadius, style: .continuous)
                        .fill(tool.tintColor.opacity(colorScheme == .dark ? 0.20 : 0.12))
                        .frame(
                            width: UtilityToolCardVisual.iconBadgeSize,
                            height: UtilityToolCardVisual.iconBadgeSize
                        )

                    Image(systemName: tool.symbolName())
                        .font(.system(size: UtilityToolCardVisual.iconGlyphSize, weight: .semibold))
                        .foregroundStyle(tool.tintColor)
                }
                .overlay(alignment: .topTrailing) {
                    if tool == .dshWeb {
                        UtilityDSHWebStatusDot(strings: strings)
                            .offset(x: 3, y: -3)
                    }
                }

                Text(tool.title(in: strings))
                    .font(Theme.Stats.font12Medium)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: UtilityToolGrid.cardHeight, maxHeight: UtilityToolGrid.cardHeight)
            .contentShape(RoundedRectangle(cornerRadius: UtilityToolCardVisual.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        // 键盘可达：Tab 聚焦到某一卡片时同样高亮并弹出描述。
        .focusable()
        .focused($isFocused)
        // 卡片样式与系统其他卡片一致；活跃态时由 omniCardStyle 的 isHovered
        // 负责填充变化，这里仅在键盘聚焦时补同一层填充，保持视觉一致。
        .omniCardStyle(
            isSelected: false,
            cornerRadius: UtilityToolCardVisual.cardCornerRadius,
            isInteractive: false
        )
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: UtilityToolCardVisual.cardCornerRadius, style: .continuous)
                    .fill(MonitorOverviewPalette.hoverFill(colorScheme))
            }
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                    guard isHovered || isFocused else { return }
                    showsHint = true
                }
            } else if !isFocused {
                showsHint = false
            }
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                showsHint = true
            } else if !isHovered {
                showsHint = false
            }
        }
        .popover(isPresented: $showsHint, arrowEdge: UtilityToolCardVisual.placementEdge) {
            UtilityToolHintBubble(text: hintText)
        }
        .accessibilityLabel(tool.title(in: strings))
        // 描述只以气泡呈现，读屏 / 辅助触控仍要能取到，故挂在无障碍提示上。
        .accessibilityHint(hintText)
    }
}

/// DSH Web 卡片状态点：极简呈现运行状态，不抢占名称空间。
private struct UtilityDSHWebStatusDot: View {
    let strings: Strings
    @ObservedObject private var manager = DSHWebManager.shared

    private var color: Color {
        switch manager.state {
        case .running: Theme.Stats.statusNormal
        case .starting, .stopping: Theme.Stats.ram
        case .failed: Theme.Stats.up
        case .stopped: Color.secondary.opacity(0.5)
        }
    }

    private var accessibilityText: String {
        switch manager.state {
        case .running: strings.dshWebStateRunning
        case .starting: strings.dshWebStateStarting
        case .stopping: strings.dshWebStateStopping
        case .failed(let reason): String(format: strings.dshWebStateFailed, reason)
        case .stopped: strings.runStateStopped
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: UtilityToolCardVisual.statusDotSize, height: UtilityToolCardVisual.statusDotSize)
            .overlay(
                Circle()
                    .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1)
            )
            .accessibilityLabel(accessibilityText)
    }
}

/// 详情页顶部返回栏已统一到共享组件 `FlatBackBar`（箭头+标题整体热区、
/// hover 反馈与发丝线容器，与监控详情页一致）。
