import SwiftUI

/// 监控总开关与采样偏好。
struct MonitorSettingsView: View {
    @ObservedObject var preferences: MonitorPreferences
    let strings: Strings

    private var isEnabled: Bool {
        preferences.configuration.isEnabled
    }

    var body: some View {
        Section {
            Toggle(strings.monitorSettingsEnable, isOn: Binding(
                get: { preferences.configuration.isEnabled },
                set: { enabled in preferences.update { $0.isEnabled = enabled } }
            ))
        }

        Section(strings.monitorSettingsTitle) {
            Picker(strings.monitorSettingsRefreshInterval, selection: Binding(
                get: { preferences.configuration.refreshInterval },
                set: { try? preferences.setRefreshInterval($0) }
            )) {
                Text("1s").tag(1)
                Text("2s").tag(2)
                Text("5s").tag(5)
            }
            Picker(strings.monitorSettingsTemperatureUnit, selection: Binding(
                get: { preferences.configuration.temperatureUnit },
                set: { unit in preferences.update { $0.temperatureUnit = unit } }
            )) {
                Text(strings.monitorSettingsCelsius).tag(TemperatureUnit.celsius)
                Text(strings.monitorSettingsFahrenheit).tag(TemperatureUnit.fahrenheit)
            }
        }
        .disabled(!isEnabled)
    }
}
