import Combine
import Foundation

/// 设置侧栏选中页的单一来源；窗口复用时由外部写入目标 tab。
final class SettingsNavigationModel: ObservableObject {
    @Published var selectedTab: SettingsToolbarTab

    init(selectedTab: SettingsToolbarTab = .general) {
        self.selectedTab = selectedTab
    }

    /// 将选中项解析到当前可见 tab；不可见时回退到第一个可见项。
    func select(
        _ tab: SettingsToolbarTab?,
        isAvailable: (AppFeature) -> Bool
    ) {
        let visible = SettingsToolbarTab.visibleCases(isAvailable: isAvailable)
        if let tab,
           let resolved = SettingsToolbarTab.resolvedSelection(tab, in: visible) {
            selectedTab = resolved
            return
        }
        if let first = visible.first {
            selectedTab = first
        }
    }
}
