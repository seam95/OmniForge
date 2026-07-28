import Combine
import Foundation
import SwiftUI

@MainActor
final class QuickPhraseOverlayState: ObservableObject {
    @Published var searchText: String = ""
    @Published var selectedGroup: String? = nil
    @Published var selectedPhraseID: UUID? = nil
    @Published var pasteTargetAppName: String? = nil

    private(set) var searchFocusToken: Int = 0
    private(set) var sessionResetToken: Int = 0

    func requestSearchFocus() {
        searchFocusToken += 1
    }

    func resetForNewSession() {
        searchText = ""
        selectedGroup = nil
        selectedPhraseID = nil
        sessionResetToken += 1
    }

    func updatePasteTargetName(_ name: String?) {
        pasteTargetAppName = name
    }
}
