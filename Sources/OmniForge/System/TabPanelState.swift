import Combine
import Foundation
import SwiftUI

enum TabPanel: String, CaseIterable, Identifiable {
    case clipboard = "剪贴板历史"
    case quickPhrase = "快捷用语"

    var id: String { rawValue }
}

@MainActor
final class TabPanelState: ObservableObject {
    @Published var selectedTab: TabPanel = .clipboard

    func toggleTab() {
        selectedTab = selectedTab == .clipboard ? .quickPhrase : .clipboard
    }

    func selectPreviousTab() {
        let all = TabPanel.allCases
        guard let index = all.firstIndex(where: { $0 == selectedTab }) else { return }
        selectedTab = index > 0 ? all[index - 1] : all[all.count - 1]
    }

    func selectNextTab() {
        let all = TabPanel.allCases
        guard let index = all.firstIndex(where: { $0 == selectedTab }) else { return }
        selectedTab = index < all.count - 1 ? all[index + 1] : all[0]
    }
}
