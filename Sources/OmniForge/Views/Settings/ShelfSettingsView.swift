import SwiftUI

struct ShelfSettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var runtime = FeatureRuntime.shared

    var body: some View {
        Form {
            ShelfSettingsSection(
                state: state,
                shelf: runtime.manager(for: .shelf, as: ShelfService.self)
            )
        }
        .settingsPageStyle()
        .id(runtime.revision)
    }
}
