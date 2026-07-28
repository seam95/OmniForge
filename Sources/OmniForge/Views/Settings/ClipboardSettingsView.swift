import SwiftUI

struct ClipboardSettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            ClipboardSettingsSection(state: state)
        }
        .settingsPageStyle()
    }
}
