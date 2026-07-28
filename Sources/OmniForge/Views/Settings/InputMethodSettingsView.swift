import SwiftUI

struct InputMethodSettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            InputMethodSettingsSection(state: state)
        }
        .settingsPageStyle()
    }
}
