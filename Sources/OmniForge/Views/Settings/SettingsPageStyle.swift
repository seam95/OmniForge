import SwiftUI

extension View {
    /// 设置页统一 chrome：系统 grouped Form，不再叠加额外水平 padding。
    func settingsPageStyle() -> some View {
        self.formStyle(.grouped)
    }
}
