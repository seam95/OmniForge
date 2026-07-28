import SwiftUI

struct MouseSettingsView: View {
    @ObservedObject var state: AppState

    private var strings: Strings { state.l10n.s }

    var body: some View {
        Form {
            MouseSettingsSection(strings: strings)
        }
        .settingsPageStyle()
    }
}
