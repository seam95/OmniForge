import SwiftUI

struct QuickPhraseView: View {
    @ObservedObject var manager: QuickPhraseManager
    @ObservedObject var uiState: QuickPhraseOverlayState
    @ObservedObject var tabState: TabPanelState
    let l10n: L10n
    let onRequestClose: () -> Void

    @State private var hoveredPhraseID: UUID?
    @State private var showEditor = false
    @State private var editingPhrase: QuickPhraseEntry?
    @FocusState private var isSearchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private let pasteService = ClipboardPasteService()

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Rectangle()
                .fill(colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08))
                .frame(height: 1)

            groupChips

            Rectangle()
                .fill(colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08))
                .frame(height: 1)

            phraseList

            Rectangle()
                .fill(colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08))
                .frame(height: 1)

            footer
        }
        .onAppear { setupKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: uiState.searchFocusToken) { _, _ in focusSearchField() }
        .onChange(of: uiState.sessionResetToken) { _, _ in resetSession() }
        .sheet(isPresented: $showEditor) {
            QuickPhraseEditorView(
                phrase: editingPhrase,
                allGroups: manager.allGroups(),
                onSave: { content, group in
                    savePhrase(content: content, group: group)
                    showEditor = false
                },
                onCancel: {
                    showEditor = false
                    editingPhrase = nil
                }
            )
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text2 : Color.secondary)

            TextField(l10n.s.quickphraseSearchPlaceholder, text: $uiState.searchText)
                .textFieldStyle(.plain)
                .font(Theme.Stats.font12Medium)
                .focused($isSearchFocused)

            if !uiState.searchText.isEmpty {
                Button(action: { uiState.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.08))
        )
    }

    private var groupChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                GroupChip(
                    title: "全部",
                    isSelected: uiState.selectedGroup == nil,
                    action: { uiState.selectedGroup = nil }
                )
                ForEach(manager.allGroups(), id: \.self) { group in
                    GroupChip(
                        title: group,
                        isSelected: uiState.selectedGroup == group,
                        action: { uiState.selectedGroup = group }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        // 过滤器选中态（SPEC §7.1 filterSelection）：chip 颜色 120ms easeOut，
        // 列表内容直接更新。
        .animation(PageSwitchMotionToken.filterSelection, value: uiState.selectedGroup)
    }

    private var phraseList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // 分组是过滤器（SPEC §5.2）：结果列表直接更新，不做整组页面转场。
                // 行 id 保持稳定（phrase.id），行状态不随分组切换重建。
                LazyVStack(spacing: 3) {
                    ForEach(filteredPhrases) { phrase in
                        PhraseRow(
                            phrase: phrase,
                            isSelected: uiState.selectedPhraseID == phrase.id,
                            isHovered: hoveredPhraseID == phrase.id,
                            onTap: { uiState.selectedPhraseID = phrase.id },
                            onDoubleTap: { paste(phrase) },
                            onEdit: { editPhrase(phrase) },
                            onDelete: { deletePhrase(phrase) },
                            onHover: { hoveredPhraseID = $0 }
                        )
                        .id(phrase.id)
                    }
                    if filteredPhrases.isEmpty {
                        emptyState
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .background(listBackground)
            .animation(Theme.Animation.pageTransition, value: uiState.selectedGroup)
            .onChange(of: uiState.selectedPhraseID) { _, newID in
                if let newID {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.6))
            Text("暂无快捷用语")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Text("点击下方「添加」按钮创建")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 80)
    }

    private var footer: some View {
        HStack {
            Button(action: { showEditor = true; editingPhrase = nil }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text("添加")
                }
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(pasteHint)
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(footerBackground)
    }

    private var filteredPhrases: [QuickPhraseEntry] {
        manager.filtered(searchText: uiState.searchText, group: uiState.selectedGroup)
    }

    private var pasteHint: String {
        if let appName = uiState.pasteTargetAppName {
            return "回车粘贴到 \(appName)"
        }
        return "回车粘贴"
    }

    private var headerBackground: Color {
        Color.clear
    }

    private var listBackground: Color {
        Color.clear
    }

    private var footerBackground: Color {
        Color.clear
    }

    private var dividerColor: Color {
        if colorScheme == .dark {
            return Color(.sRGB, red: 0.27, green: 0.29, blue: 0.34, opacity: 1)
        }
        return Color(.sRGB, red: 0.74, green: 0.76, blue: 0.80, opacity: 1)
    }

    private func focusSearchField() {
        DispatchQueue.main.async {
            isSearchFocused = true
        }
    }

    private func resetSession() {
        uiState.searchText = ""
        uiState.selectedGroup = nil
        uiState.selectedPhraseID = nil
    }

    private func setupKeyMonitor() {
        // Key handling in ClipboardWindowController
    }

    private func removeKeyMonitor() {
        // Key handling in ClipboardWindowController
    }

    private func paste(_ phrase: QuickPhraseEntry) {
        let entry = ClipboardEntry(
            id: UUID(),
            createdAt: Date(),
            type: .text,
            preview: String(phrase.content.prefix(80)),
            sourceAppBundleID: nil,
            sourceAppName: nil,
            content: .text(phrase.content),
            thumbnailData: nil,
            blobSize: nil,
            imageWidth: nil,
            imageHeight: nil,
            contentHash: nil
        )

        pasteService.paste(entry: entry, close: onRequestClose)
    }

    private func editPhrase(_ phrase: QuickPhraseEntry) {
        editingPhrase = phrase
        showEditor = true
    }

    private func savePhrase(content: String, group: String?) {
        if let existing = editingPhrase {
            manager.update(id: existing.id, content: content, group: group)
        } else {
            manager.add(content: content, group: group)
        }
        editingPhrase = nil
    }

    private func deletePhrase(_ phrase: QuickPhraseEntry) {
        manager.delete(id: phrase.id)
        if uiState.selectedPhraseID == phrase.id {
            uiState.selectedPhraseID = nil
        }
    }
}

private struct GroupChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(chipBackground)
                .foregroundColor(chipForeground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                        .strokeBorder(chipBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Theme.Animation.hover) {
                isHovered = hovering
            }
        }
    }

    private var chipBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.25 : 0.15)
        } else {
            return isHovered
                ? Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06)
                : Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03)
        }
    }

    private var chipBorder: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.45 : 0.35)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04)
    }

    private var chipForeground: Color {
        if isSelected {
            return Color.accentColor
        } else {
            return isHovered ? .primary : .secondary
        }
    }
}

private struct PhraseRow: View {
    let phrase: QuickPhraseEntry
    let isSelected: Bool
    let isHovered: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onHover: (UUID?) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.2) : Color.accentColor.opacity(0.1))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "text.quote")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isSelected ? .white : .accentColor)
                )

            VStack(alignment: .leading, spacing: 2) {
                ForEach(phrase.previewLines.prefix(1), id: \.self) { line in
                    Text(line)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isSelected ? .white : .primary)
                        .lineLimit(1)
                }
                
                if let group = phrase.group, !group.isEmpty {
                    Text(group)
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white : .secondary.opacity(0.6))
                        .frame(width: 24, height: 24)
                        .background(isSelected ? Color.white.opacity(0.2) : actionBg)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white : .secondary.opacity(0.6))
                        .frame(width: 24, height: 24)
                        .background(isSelected ? Color.white.opacity(0.2) : actionBg)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            .opacity((isHovered || isSelected) ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(rowBackground)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded { onDoubleTap() }
        )
        .onHover { isHovered in
            onHover(isHovered ? phrase.id : nil)
        }
        .contextMenu {
            Button(action: onEdit) { Label("编辑", systemImage: "pencil") }
            Divider()
            Button(action: onDelete) { Label("删除", systemImage: "trash") }
        }
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor
        } else if isHovered {
            return Color.primary.opacity(0.05)
        } else {
            return .clear
        }
    }

    private var actionBg: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08)
    }
}
