import Combine
import Foundation

@MainActor
final class ClipboardOverlayState: ObservableObject {
    @Published var searchText: String = ""
    @Published var filter: ClipboardFilter = .all
    @Published var selectedEntryID: UUID?
    @Published var pasteTargetAppName: String?
    @Published private(set) var searchFocusToken: Int = 0
    @Published private(set) var sessionResetToken: Int = 0
    /// 键盘 ↑↓ 导航时递增；View 据此滚动到选中项（避免依赖 View 级 NSEvent monitor）。
    @Published private(set) var keyboardSelectionToken: Int = 0

    func resetForNewSession() {
        searchText = ""
        filter = .all
        selectedEntryID = nil
        sessionResetToken += 1
    }

    func moveSelection(in entries: [ClipboardEntry], direction: Int) {
        selectedEntryID = ClipboardSelectionNavigator.nextSelection(
            in: entries,
            currentID: selectedEntryID,
            direction: direction
        )
        keyboardSelectionToken += 1
    }

    func filteredEntries(from entries: [ClipboardEntry]) -> [ClipboardEntry] {
        entries.filter { entry in
            filter.matches(entry.type)
        }.filter { entry in
            guard !searchText.isEmpty else { return true }
            return entry.preview.localizedCaseInsensitiveContains(searchText)
        }
    }

    func updateSelectionIfNeeded(in entries: [ClipboardEntry]) {
        guard !entries.isEmpty else {
            selectedEntryID = nil
            return
        }

        if let selectedEntryID, entries.contains(where: { $0.id == selectedEntryID }) {
            return
        }

        selectedEntryID = entries.first?.id
    }

    func requestSearchFocus() {
        searchFocusToken += 1
    }

}
