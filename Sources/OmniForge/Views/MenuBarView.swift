import SwiftUI

struct MenuBarView: View {
    @ObservedObject var state: AppState
    let onOpenClipboard: () -> Void
    var onOpenSettings: () -> Void = {}

    var body: some View {
        MainPanelView(
            state: state,
            onOpenClipboard: onOpenClipboard,
            onOpenSettings: onOpenSettings
        )
    }
}
