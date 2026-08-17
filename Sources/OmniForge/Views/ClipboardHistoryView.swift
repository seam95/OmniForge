import AppKit
import Carbon
import NaturalLanguage
import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject var history: ClipboardHistoryManager
    @ObservedObject var l10n: L10n
    @ObservedObject var uiState: ClipboardOverlayState
    let onRequestClose: () -> Void
    let isReadyToPaste: () -> Bool
    let pasteTargetPIDProvider: () -> pid_t?

    @State private var loadedEntryCount: Int = 15

    // 派生数据缓存：避免每次 body 重算都重新过滤/分组（hover、选中变化等都会触发 body 重算）
    @State private var filteredCache: [ClipboardEntry]?
    @State private var groupedCache: [ClipboardHistoryGroup]?
    @FocusState private var isSearchFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    private let pasteService = ClipboardPasteService()

    private static let detailTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter
    }()

    private static let initialLoadCount = 15
    private static let loadMoreBatchCount = 15
    private static let loadMoreTriggerDistance = 5

    private var filteredEntries: [ClipboardEntry] {
        if let filteredCache { return filteredCache }
        return uiState.filteredEntries(from: history.entries)
    }

    private var visibleEntries: [ClipboardEntry] {
        return Array(filteredEntries.prefix(loadedEntryCount))
    }

    private var groupedEntries: [ClipboardHistoryGroup] {
        if let groupedCache { return groupedCache }
        return ClipboardHistoryGrouper.groups(entries: visibleEntries)
    }

    private var selectedEntry: ClipboardEntry? {
        guard let selectedEntryID = uiState.selectedEntryID else { return nil }
        return history.entries.first { $0.id == selectedEntryID }
    }

    private var pasteTargetAppName: String {
        if let name = uiState.pasteTargetAppName, !name.isEmpty {
            return name
        }
        return l10n.s.clipboardPasteUnknown
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Rectangle()
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
                .frame(height: 1)

            contentArea

            Rectangle()
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
                .frame(height: 1)

            footer
        }
        .onAppear {
            rebuildDerivedState()
            focusSearchField()
        }
        .onChange(of: history.entries) { _, _ in
            rebuildDerivedState()
        }
        .onChange(of: uiState.searchText) { _, _ in
            rebuildDerivedState()
        }
        .onChange(of: uiState.filter) { _, _ in
            rebuildDerivedState()
        }
        .onChange(of: loadedEntryCount) { _, _ in
            rebuildVisibleAndGroupedOnly()
        }
        .onChange(of: uiState.searchFocusToken) { _, _ in
            focusSearchField()
        }
    }

    private var footer: some View {
        HStack {
            Text(l10n.s.clipboardTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

            pasteHint
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            searchField
            filterMenu
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(l10n.s.clipboardSearch, text: $uiState.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isSearchFocused)

            if !uiState.searchText.isEmpty {
                Button(action: { uiState.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var filterMenu: some View {
        Menu {
            Picker("", selection: $uiState.filter) {
                ForEach(ClipboardFilter.allCases) { item in
                    Text(item.label(in: l10n.s)).tag(item)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(uiState.filter.label(in: l10n.s))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7.5)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private var contentArea: some View {
        HStack(spacing: 0) {
            historyList
                .frame(width: 270)

            Rectangle()
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
                .frame(width: 1)

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var detailPane: some View {
        Group {
            if let entry = selectedEntry {
                VStack(spacing: 0) {
                    detailPreview(entry)
                        .frame(maxHeight: .infinity)

                    Rectangle()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
                        .frame(height: 1)

                    detailInfo(entry)
                        .frame(height: 160)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "clipboard")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text(l10n.s.clipboardEmpty)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var pasteHint: some View {
        HStack(spacing: 10) {
            Text(l10n.s.clipboardPasteHint)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(pasteTargetAppName)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Image(systemName: "return")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)
        )
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if groupedEntries.isEmpty {
                        Text(l10n.s.clipboardEmpty)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .padding(.top, 28)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        ForEach(groupedEntries, id: \.section) { group in
                            sectionHeader(title: group.section.title(in: l10n.s))
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                .padding(.bottom, 2)

                            ForEach(group.entries) { entry in
                                ClipboardHistoryRow(
                                    entry: entry,
                                    isSelected: uiState.selectedEntryID == entry.id,
                                    pasteActionTitle: l10n.s.clipboardActionPaste,
                                    onTap: {
                                        uiState.selectedEntryID = entry.id
                                    },
                                    onPaste: {
                                        pasteEntry(entry)
                                    },
                                    onAppear: {
                                        loadMoreIfNeeded(currentEntry: entry)
                                    }
                                )
                                .id(entry.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onAppear {
                resetLoadedEntriesForNewSession()
                updateSelectionIfNeeded()
                scrollToTop(proxy: proxy, animated: false)
            }
            .onChange(of: uiState.sessionResetToken) { _, _ in
                resetLoadedEntriesForNewSession()
                updateSelectionIfNeeded()
                scrollToTop(proxy: proxy, animated: false)
            }
            // 键盘导航由 ClipboardWindowController 更新 selectedEntryID + keyboardSelectionToken；
            // View 只负责扩容懒加载窗口并滚动到选中项。
            .onChange(of: uiState.keyboardSelectionToken) { _, _ in
                ensureSelectedEntryLoaded()
                guard let selectedEntryID = uiState.selectedEntryID else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(selectedEntryID)
                }
            }
        }
    }

    private func sectionHeader(title: String) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    private func detailPreview(_ entry: ClipboardEntry) -> some View {
        detailContent(entry)
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func detailInfo(_ entry: ClipboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            detailGroupHeader

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], spacing: 8) {
                infoBadge(
                    title: l10n.s.clipboardDetailSource,
                    value: entry.sourceAppName ?? "-",
                    icon: "app.dashed"
                )
                infoBadge(
                    title: l10n.s.clipboardDetailType,
                    value: entry.type.label(in: l10n.s),
                    icon: entry.iconName
                )
                if let dimensionLabel = dimensionDescription(for: entry) {
                    infoBadge(
                        title: l10n.s.clipboardDetailDimensions,
                        value: dimensionLabel,
                        icon: "aspectratio"
                    )
                }
                if let sizeLabel = sizeDescription(for: entry) {
                    infoBadge(
                        title: l10n.s.clipboardDetailSize,
                        value: sizeLabel,
                        icon: "internaldrive"
                    )
                }
                infoBadge(
                    title: l10n.s.clipboardDetailCharacters,
                    value: metadataDescription(for: entry),
                    icon: "text.alignleft"
                )
                infoBadge(
                    title: l10n.s.clipboardDetailTime,
                    value: formattedTime(entry.createdAt),
                    icon: "clock"
                )
            }
        }
        .padding(14)
    }

    private func infoBadge(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04), lineWidth: 1)
        )
    }

    private func detailContent(_ entry: ClipboardEntry) -> some View {
        Group {
            switch entry.content {
            case .text:
                if let text = fullText(for: entry) {
                    SelectableTextView(text: text, font: .systemFont(ofSize: 16))
                } else {
                    Text(l10n.s.clipboardDetailUnavailable)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            case .url(let url):
                SelectableTextView(text: url.absoluteString, font: .systemFont(ofSize: 16))
            case .files(let files):
                SelectableTextView(
                    text: files.map(\.lastPathComponent).joined(separator: "\n"),
                    font: .systemFont(ofSize: 16)
                )
            case .image:
                GeometryReader { proxy in
                    let maxPointSize = max(proxy.size.width, min(proxy.size.height, 320))
                    let maxPixelSize = Int(ceil(maxPointSize * displayScale))

                    if let image = ClipboardImageCache.shared.detailImage(
                        for: entry.id,
                        maxPixelSize: maxPixelSize,
                        loader: {
                            guard let fullContent = history.fullContent(for: entry.id),
                                  case .image(let data) = fullContent else {
                                return nil
                            }
                            return data
                        }
                    ) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text(l10n.s.clipboardDetailUnavailable)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxHeight: 320)
            case .rtf:
                Text(l10n.s.clipboardDetailRtf)
                    .font(.system(size: 15))
            case .unknown:
                Text(l10n.s.clipboardDetailUnavailable)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detailGroupHeader: some View {
        Text(l10n.s.clipboardDetailInformation)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metadataDescription(for entry: ClipboardEntry) -> String {
        switch entry.content {
        case .text:
            guard let text = fullText(for: entry) else { return "-" }
            let characters = text.count
            let words = wordCount(for: text)
            let characterLabel = l10n.s.clipboardDetailCharactersCount
            let wordLabel = l10n.s.clipboardDetailWordsCount
            if words > 0 {
                return "\(characters) \(characterLabel) · \(words) \(wordLabel)"
            } else {
                return "\(characters) \(characterLabel)"
            }
        default:
            return "-"
        }
    }

    private func fullText(for entry: ClipboardEntry) -> String? {
        if case .text(let text?) = entry.content {
            return text
        }
        guard let content = history.fullContent(for: entry.id),
              case .text(let text?) = content else {
            return nil
        }
        return text
    }

    private func dimensionDescription(for entry: ClipboardEntry) -> String? {
        guard entry.type == .image else { return nil }
        if let w = entry.imageWidth, let h = entry.imageHeight {
            return "\(w) × \(h) px"
        }
        return l10n.s.clipboardDetailImageUnknown
    }

    private func sizeDescription(for entry: ClipboardEntry) -> String? {
        switch entry.type {
        case .image:
            guard entry.blobSize > 0 else { return nil }
            return Self.byteFormatter.string(fromByteCount: entry.blobSize)
        case .text:
            guard entry.blobSize > 0 else { return nil }
            return Self.byteFormatter.string(fromByteCount: entry.blobSize)
        default:
            return nil
        }
    }

    private func wordCount(for text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if !text[range].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
            return true
        }
        return count
    }

    private func formattedTime(_ date: Date) -> String {
        Self.detailTimeFormatter.string(from: date)
    }

    private func updateSelectionIfNeeded() {
        uiState.updateSelectionIfNeeded(in: filteredEntries)
    }

    /// 重新计算派生数据（filtered → loadedEntryCount → grouped）
    /// 在 entries / searchText / filter 变化，或首次出现时调用
    private func rebuildDerivedState() {
        let filtered = uiState.filteredEntries(from: history.entries)
        filteredCache = filtered

        // clamp loadedEntryCount 到 [initialLoadCount, filtered.count]，并确保选中项在 loaded 范围内
        var newLoadedCount = min(max(loadedEntryCount, Self.initialLoadCount), filtered.count)
        if let selectedEntryID = uiState.selectedEntryID,
           let selectedIndex = filtered.firstIndex(where: { $0.id == selectedEntryID }) {
            newLoadedCount = min(filtered.count, max(newLoadedCount, selectedIndex + 1))
        }
        loadedEntryCount = newLoadedCount

        rebuildVisibleAndGroupedOnly()

        updateSelectionIfNeeded()
    }

    /// 仅重建 grouped（filtered 不变，loadedEntryCount 变化时调用）
    private func rebuildVisibleAndGroupedOnly() {
        guard let filtered = filteredCache else { return }
        let visible = Array(filtered.prefix(loadedEntryCount))
        groupedCache = ClipboardHistoryGrouper.groups(entries: visible)
    }

    private func loadMoreIfNeeded(currentEntry: ClipboardEntry) {
        let visible = visibleEntries
        guard let currentIndex = visible.firstIndex(where: { $0.id == currentEntry.id }) else { return }
        let thresholdIndex = max(0, visible.count - Self.loadMoreTriggerDistance)
        guard currentIndex >= thresholdIndex else { return }

        let filteredCount = filteredEntries.count
        guard loadedEntryCount < filteredCount else { return }

        loadedEntryCount = min(loadedEntryCount + Self.loadMoreBatchCount, filteredCount)
    }

    private func scrollToSelectedEntry(proxy: ScrollViewProxy, animated: Bool) {
        guard let selectedEntryID = uiState.selectedEntryID,
              visibleEntries.contains(where: { $0.id == selectedEntryID }) else {
            return
        }

        let action = {
            proxy.scrollTo(selectedEntryID, anchor: .center)
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.12)) {
                action()
            }
        } else {
            action()
        }
    }

    private func scrollToTop(proxy: ScrollViewProxy, animated: Bool) {
        guard let firstEntryID = visibleEntries.first?.id else { return }

        let action = {
            proxy.scrollTo(firstEntryID, anchor: .top)
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.12)) {
                action()
            }
        } else {
            action()
        }
    }

    private func resetLoadedEntriesForNewSession() {
        loadedEntryCount = min(Self.initialLoadCount, filteredEntries.count)
    }

    private func focusSearchField() {
        DispatchQueue.main.async {
            isSearchFocused = true
        }
    }

    /// 键盘选中可能越过懒加载窗口，扩展 loadedEntryCount 保证选中项可渲染/可滚动。
    private func ensureSelectedEntryLoaded() {
        guard let selectedEntryID = uiState.selectedEntryID else { return }
        let entries = filteredEntries
        guard let index = entries.firstIndex(where: { $0.id == selectedEntryID }) else { return }
        let needed = index + 1
        if loadedEntryCount < needed {
            loadedEntryCount = min(entries.count, needed)
        }
    }

    private func pasteEntry(_ entry: ClipboardEntry) {
        // blob 类型的条目可能 Data 为 nil（轻量模式），需要先从 DB 加载完整内容
        var entryToPaste = entry
        switch entry.content {
        case .text(nil), .image(nil), .rtf(nil), .unknown(nil):
            if let fullContent = history.fullContent(for: entry.id) {
                entryToPaste = entry.withContent(fullContent)
            }
        default:
            break
        }
        pasteService.paste(
            entry: entryToPaste,
            close: onRequestClose,
            isReadyToPaste: isReadyToPaste,
            targetPID: pasteTargetPIDProvider()
        )
    }

}

/// 剪贴板历史列表行视图
///
/// hover 状态局部化为本 View 的 @State，避免鼠标经过行时修改父 View 状态、
/// 进而打断整个 ClipboardHistoryView 的 body（这是滚动卡顿的主要元凶）。
private struct ClipboardHistoryRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool
    let pasteActionTitle: String
    let onTap: () -> Void
    let onPaste: () -> Void
    let onAppear: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            leadingIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.preview)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)

                if let appName = entry.sourceAppName {
                    Text(appName)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(rowBackground)
        .contextMenu {
            Button(pasteActionTitle) {
                onPaste()
            }
        }
        .onTapGesture {
            onTap()
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onPaste()
            }
        )
        .onHover { hovering in
            withAnimation(Theme.Animation.hover) {
                isHovered = hovering
            }
        }
        .onAppear {
            onAppear()
        }
    }

    private var leadingIcon: some View {
        ZStack {
            if entry.type == .image,
               let thumbnail = ClipboardImageCache.shared.thumbnailImage(for: entry.id, data: entry.thumbnailData) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.22) : Color.primary.opacity(0.05))
                    .frame(width: 32, height: 32)

                Image(systemName: entry.iconName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .secondary)
            }
        }
        .frame(width: 32, height: 32)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .fill(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
    }
}

@MainActor
struct ClipboardHistoryRowActionHandler {
    let select: (UUID) -> Void
    let paste: (ClipboardEntry) -> Void

    func handleClick(entry: ClipboardEntry, clickCount: Int) {
        if clickCount >= 2 {
            paste(entry)
        } else {
            select(entry.id)
        }
    }
}

@MainActor
struct ClipboardHistoryKeyHandler {
    let moveSelection: (Int) -> Void
    let paste: () -> Void

    nonisolated static func scrollAnchor(forMoveDirection direction: Int) -> ClipboardHistoryScrollAnchor {
        direction > 0 ? .bottom : .top
    }

    func handleKeyDown(keyCode: UInt16) -> Bool {
        switch keyCode {
        case UInt16(kVK_UpArrow):
            moveSelection(-1)
            return true
        case UInt16(kVK_DownArrow):
            moveSelection(1)
            return true
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            paste()
            return true
        default:
            return false
        }
    }
}

enum ClipboardHistoryScrollAnchor: Equatable {
    case top
    case bottom

    var unitPoint: UnitPoint {
        switch self {
        case .top:
            return .top
        case .bottom:
            return .bottom
        }
    }
}

struct ClipboardHistoryScrollPlanner {
    static func plannedAnchor(
        oldSelectedID: UUID?,
        newSelectedID: UUID,
        entries: [ClipboardEntry]
    ) -> ClipboardHistoryScrollAnchor? {
        guard let oldSelectedID else { return nil }
        guard let oldIndex = entries.firstIndex(where: { $0.id == oldSelectedID }) else { return nil }
        guard let newIndex = entries.firstIndex(where: { $0.id == newSelectedID }) else { return nil }

        let direction = newIndex - oldIndex
        guard direction != 0 else { return nil }

        return ClipboardHistoryKeyHandler.scrollAnchor(forMoveDirection: direction)
    }
}

struct ClipboardHistoryScrollDecider {
    static func shouldScroll(selectedID: UUID, visibleIDs: Set<UUID>) -> Bool {
        guard !visibleIDs.isEmpty else { return false }
        return visibleIDs.contains(selectedID) == false
    }
}

struct ThinScrollIndicatorVisibilityTracker {
    private(set) var isVisible = false

    mutating func requestShow() -> Bool {
        guard !isVisible else { return false }
        isVisible = true
        return true
    }

    mutating func requestHide() -> Bool {
        guard isVisible else { return false }
        isVisible = false
        return true
    }
}

private extension ClipboardContentType {
    /// 返回该内容类型的本地化标签
    func label(in strings: Strings) -> String {
        switch self {
        case .text: return strings.clipboardFilterText
        case .image: return strings.clipboardFilterImage
        case .file: return strings.clipboardFilterFile
        case .url: return strings.clipboardFilterUrl
        case .rtf: return strings.clipboardFilterRtf
        case .unknown: return strings.clipboardFilterUnknown
        }
    }
}

private struct ThinScrollIndicatorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(ThinScrollIndicatorApplier())
    }
}

private struct ThinScrollIndicatorApplier: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let scrollView = nsView.enclosingScrollView else { return }
            context.coordinator.attach(to: scrollView)
        }
    }

    final class Coordinator: NSObject {
        private weak var scrollView: NSScrollView?
        private var hideTask: DispatchWorkItem?
        private var isObserving = false
        private var visibilityTracker = ThinScrollIndicatorVisibilityTracker()

        func attach(to scrollView: NSScrollView) {
            if self.scrollView !== scrollView {
                detach()
                self.scrollView = scrollView
                prepare(scrollView)
            }
            showTemporarily()
        }

        private func prepare(_ scrollView: NSScrollView) {
            scrollView.scrollerStyle = .overlay
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            configure(scroller: scrollView.verticalScroller)
            configure(scroller: scrollView.horizontalScroller)

            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(contentBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            isObserving = true
            setIndicatorsVisible(false, animated: false)
        }

        private func configure(scroller: NSScroller?) {
            scroller?.controlSize = .mini
        }

        @objc private func contentBoundsDidChange() {
            showTemporarily()
        }

        private func showTemporarily() {
            if visibilityTracker.requestShow() {
                setIndicatorsVisible(true, animated: true)
            }
            scheduleHide()
        }

        private func scheduleHide() {
            hideTask?.cancel()
            let task = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.visibilityTracker.requestHide() {
                    self.setIndicatorsVisible(false, animated: true)
                }
            }
            hideTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: task)
        }

        private func setIndicatorsVisible(_ isVisible: Bool, animated: Bool) {
            guard let scrollView else { return }
            let alpha: CGFloat = isVisible ? 0.9 : 0
            let animator: (NSScroller?) -> Void = { scroller in
                guard let scroller else { return }
                if animated {
                    scroller.animator().alphaValue = alpha
                } else {
                    scroller.alphaValue = alpha
                }
            }

            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    animator(scrollView.verticalScroller)
                    animator(scrollView.horizontalScroller)
                }
            } else {
                animator(scrollView.verticalScroller)
                animator(scrollView.horizontalScroller)
            }
        }

        private func detach() {
            hideTask?.cancel()
            if isObserving, let contentView = scrollView?.contentView {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: contentView)
            }
            isObserving = false
            visibilityTracker = ThinScrollIndicatorVisibilityTracker()
            scrollView = nil
        }

        deinit {
            detach()
        }
    }
}

private extension View {
    func thinScrollIndicators() -> some View {
        modifier(ThinScrollIndicatorModifier())
    }
}

// MARK: - 可选中文本视图

/// 包裹 NSTextView 的只读可选文本视图，支持鼠标拖选和 ⌘C 复制
private struct SelectableTextView: NSViewRepresentable {
    let text: String
    let font: NSFont

    func makeNSView(context: Context) -> NSScrollView {
        // 使用标准的 scrollableTextView 工厂方法创建,确保 textView 的 maxSize / autoresizingMask /
        // widthTracksTextView 配置正确。若用 NSTextView() 默认初始化,textView 初始 frame 为 .zero 且
        // 缺少 autoresizingMask,会导致 textContainer 宽度为 0,文本无法布局和绘制(右侧详情预览区空白)。
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = .labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticLinkDetectionEnabled = false
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.font = font
            textView.textColor = .labelColor
        }
    }
}

private extension ClipboardEntry {
    var iconName: String {
        switch type {
        case .text:
            return "doc.text"
        case .image:
            return "photo"
        case .file:
            return "doc"
        case .url:
            return "link"
        case .rtf:
            return "doc.richtext"
        case .unknown:
            return "questionmark"
        }
    }
}
