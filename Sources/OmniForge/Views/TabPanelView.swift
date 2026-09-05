import SwiftUI

struct TabPanelView: View {
    @ObservedObject var tabState: TabPanelState
    let clipboardView: ClipboardHistoryView
    let quickPhraseView: QuickPhraseView

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabIndicator

    var body: some View {
        VStack(spacing: 0) {
            tabHeader
                .padding(.top, 4)
            contentView
        }
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(minWidth: 720, minHeight: 460)
        .omniNoFocusRing()
    }

    private var tabHeader: some View {
        HStack(spacing: 4) {
            ForEach(TabPanel.allCases) { tab in
                TabButton(
                    title: tab.rawValue,
                    isSelected: tabState.selectedTab == tab,
                    indicatorNamespace: tabIndicator,
                    indicatorAnimation: PageSwitchMotionToken.selectionIndicator(
                        reduceMotion: reduceMotion
                    ),
                    reducesIndicatorMotion: reduceMotion,
                    action: {
                        tabState.selectedTab = tab
                    }
                )
            }
        }
        // 选中底块动画（SPEC §7.1 selectionIndicator；Reduce Motion 降级）。
        .animation(
            PageSwitchMotionToken.selectionIndicator(reduceMotion: reduceMotion),
            value: tabState.selectedTab
        )
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(headerBackground)
    }

    @ViewBuilder
    private var contentView: some View {
        // 剪贴板历史/快捷短语平级切换：按 tab 顺序方向化滑移（SPEC 三期）。
        PageSwitchHost(
            requestedRoute: tabState.selectedTab,
            semantics: { from, to in
                .lateral(from: from, to: to, order: TabPanel.allCases)
            },
            surface: { _ in .clear }
        ) { tab in
            switch tab {
            case .clipboard:
                clipboardView
            case .quickPhrase:
                quickPhraseView
            }
        }
    }

    private var background: Color {
        if colorScheme == .dark {
            return Color(nsColor: .windowBackgroundColor).opacity(0.98)
        }
        return Color(nsColor: .windowBackgroundColor).opacity(0.99)
    }

    private var headerBackground: Color {
        Color.clear
    }
}

private struct TabButton: View {
    /// 选中底块 matchedGeometry 标识：底块在 tab 间平滑滑移。
    private static let activeIndicatorID = "tab-panel-active"

    let title: String
    let isSelected: Bool
    let indicatorNamespace: Namespace.ID
    /// 选中底块滑移动画（Reduce Motion 下降级为透明度过渡）。
    var indicatorAnimation: Animation = PageSwitchMotionToken.selectionIndicator(reduceMotion: false)
    /// Reduce Motion：取消 matchedGeometry 位置插值，底块就地淡切（SPEC §7.4.3）。
    var reducesIndicatorMotion = false
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isSelected ? .primary : .secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(
                    ZStack {
                        // Reduce Motion 下底块就地渲染 + 透明度过渡，无位置插值（SPEC §7.4.3）。
                        if isSelected {
                            if reducesIndicatorMotion {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selectedBackground)
                                    .shadow(color: Color.black.opacity(0.1), radius: 2, y: 1)
                                    .transition(.opacity)
                            } else {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selectedBackground)
                                    .shadow(color: Color.black.opacity(0.1), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: Self.activeIndicatorID, in: indicatorNamespace)
                            }
                        }
                    }
                )
        }
        .buttonStyle(.plain)
    }

    private var selectedBackground: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.12)
        }
        return Color.white.opacity(0.8)
    }
}
