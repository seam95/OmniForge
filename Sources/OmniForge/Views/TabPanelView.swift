import SwiftUI

struct TabPanelView: View {
    @ObservedObject var tabState: TabPanelState
    let clipboardView: ClipboardHistoryView
    let quickPhraseView: QuickPhraseView

    @Environment(\.colorScheme) private var colorScheme
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
                    action: {
                        tabState.selectedTab = tab
                    }
                )
            }
        }
        // 动画统一由 value 驱动：按钮点击、快捷键切换、外部赋值同享一套转场。
        .animation(Theme.Animation.pageTransition, value: tabState.selectedTab)
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(headerBackground)
    }

    @ViewBuilder
    private var contentView: some View {
        // ZStack 让新旧 tab 内容在转场期间叠放淡切。
        ZStack {
            switch tabState.selectedTab {
            case .clipboard:
                clipboardView
                    .peerTransition()
            case .quickPhrase:
                quickPhraseView
                    .peerTransition()
            }
        }
        .animation(Theme.Animation.pageTransition, value: tabState.selectedTab)
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
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .primary : .secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(
                    ZStack {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selectedBackground)
                                .shadow(color: Color.black.opacity(0.1), radius: 2, y: 1)
                                .matchedGeometryEffect(id: Self.activeIndicatorID, in: indicatorNamespace)
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
