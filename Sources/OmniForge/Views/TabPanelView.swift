import SwiftUI

struct TabPanelView: View {
    @ObservedObject var tabState: TabPanelState
    let clipboardView: ClipboardHistoryView
    let quickPhraseView: QuickPhraseView

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            tabHeader
                .padding(.top, 4)
            contentView
        }
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(minWidth: 720, minHeight: 460)
    }

    private var tabHeader: some View {
        HStack(spacing: 4) {
            ForEach(TabPanel.allCases) { tab in
                TabButton(
                    title: tab.rawValue,
                    isSelected: tabState.selectedTab == tab,
                    action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            tabState.selectedTab = tab
                        }
                    }
                )
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(headerBackground)
    }

    @ViewBuilder
    private var contentView: some View {
        switch tabState.selectedTab {
        case .clipboard:
            clipboardView
        case .quickPhrase:
            quickPhraseView
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
    let title: String
    let isSelected: Bool
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
