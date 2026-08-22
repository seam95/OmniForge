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
        case .compact: 356
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .settings: 28
        case .compact: 12
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

enum UtilityToolsPresentation {
    static func resolvedSelection(
        storedRawValue: String,
        visibleTools: [UtilityTool]
    ) -> UtilityTool? {
        UtilityTool.resolvedSelection(UtilityTool(rawValue: storedRawValue), in: visibleTools)
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
    @AppStorage(UserDefaultsKeys.lastUtilityTool) private var storedTool = UtilityTool.cleaner.rawValue

    /// 本页内部导航：列表 ↔ 详情。不持久化，切回本 tab 默认落在列表。
    @State private var route: Route = .list

    init(strings: Strings) {
        self.init(strings: strings, runtime: .shared)
    }

    init(strings: Strings, runtime: FeatureRuntime) {
        self.strings = strings
        self.runtime = runtime
    }

    private enum Route: Equatable {
        case list
        case detail(UtilityTool)
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
        VStack(spacing: 0) {
            switch route {
            case .list:
                toolListView
            case .detail(let tool):
                toolDetailView(tool)
            }
        }
        // 宽度拉满；高度跟随子工具内容，供控制中心 popover 按 tab 自适应。
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            repairSelection()
            route = autoRoute()
        }
        .onChange(of: runtime.revision) { _, _ in
            repairSelection()
            // 当前详情的工具被卸载时退回列表，避免渲染不可用工具。
            if case .detail(let tool) = route, !visibleTools.contains(tool) {
                route = .list
            }
        }
    }

    /// 单工具可见时跳过列表直进详情，与原分段逻辑的 count==1 分支同构。
    private func autoRoute() -> Route {
        visibleTools.count == 1 ? .detail(visibleTools[0]) : .list
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
            VStack(spacing: 0) {
                ForEach(Array(visibleTools.enumerated()), id: \.element.id) { index, tool in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
                            .frame(height: 1)
                    }
                    UtilityToolRow(tool: tool, strings: strings) {
                        enterDetail(tool)
                    }
                }
            }
            .background(UtilityListChrome.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), lineWidth: 1)
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.20 : 0.05),
                radius: 8,
                x: 0,
                y: 2
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    private func enterDetail(_ tool: UtilityTool) {
        storedTool = tool.rawValue
        route = .detail(tool)
    }

    @ViewBuilder
    private func toolDetailView(_ tool: UtilityTool) -> some View {
        VStack(spacing: 0) {
            UtilityToolDetailBar(title: tool.hubName(in: strings), strings: strings) {
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
        }
    }

    private func repairSelection() {
        guard let repaired = selectedTool else { return }
        if storedTool != repaired.rawValue {
            storedTool = repaired.rawValue
        }
    }
}

/// 实用工具列表行：多彩图标 + 标题/描述 + chevron/状态药丸，整行可点。
private struct UtilityToolRow: View {
    let tool: UtilityTool
    let strings: Strings
    let onTap: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tool.tintColor.opacity(colorScheme == .dark ? 0.20 : 0.12))
                        .frame(width: 38, height: 38)

                    Image(systemName: tool.symbolName())
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundStyle(tool.tintColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.title(in: strings))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(tool.hubDescription(in: strings))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                if tool == .dshWeb {
                    UtilityDSHWebStatusBadge(strings: strings)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(Color.primary.opacity(0.22))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.03) : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(tool.title(in: strings))
        .accessibilityHint(strings.controlcenterTabUtilities)
    }
}

/// DSH Web 服务列表行状态徽章
private struct UtilityDSHWebStatusBadge: View {
    let strings: Strings
    @ObservedObject private var manager = DSHWebManager.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch manager.state {
        case .running:
            HStack(spacing: 4.5) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5.5, height: 5.5)
                Text(strings.dshWebStateRunning)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.green)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(Color.green.opacity(colorScheme == .dark ? 0.20 : 0.12))
            )
        case .starting:
            HStack(spacing: 4.5) {
                ProgressView()
                    .controlSize(.mini)
                Text(strings.dshWebStateStarting)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.orange)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(Color.orange.opacity(colorScheme == .dark ? 0.20 : 0.12))
            )
        case .stopping:
            HStack(spacing: 4.5) {
                ProgressView()
                    .controlSize(.mini)
                Text(strings.dshWebStateStopping)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.orange)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(Color.orange.opacity(colorScheme == .dark ? 0.20 : 0.12))
            )
        case .failed:
            HStack(spacing: 4.5) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 5.5, height: 5.5)
                Text("异常")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.red)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(Color.red.opacity(colorScheme == .dark ? 0.20 : 0.12))
            )
        case .stopped:
            HStack(spacing: 4.5) {
                Circle()
                    .fill(Color.secondary.opacity(0.7))
                    .frame(width: 5.5, height: 5.5)
                Text(strings.runStateStopped)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04))
            )
        }
    }
}

/// 详情页顶部返回栏：返回按钮 + 工具标题。
private struct UtilityToolDetailBar: View {
    let title: String
    let strings: Strings
    let onBack: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isBackHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isBackHovered ? Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isBackHovered = $0 }
            .accessibilityLabel(strings.controlcenterTabUtilities)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
    }
}

private enum UtilityListChrome {
    @ViewBuilder
    static var cardBackground: some View {
        UtilityListCardBackground()
    }
}

private struct UtilityListCardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if colorScheme == .dark {
                Color.white.opacity(0.06)
            } else {
                Color.white
            }
        }
    }
}
