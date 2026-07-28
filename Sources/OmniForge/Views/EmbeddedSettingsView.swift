import SwiftUI

struct EmbeddedSettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            SettingsView(state: state, useScrollContainer: false)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
