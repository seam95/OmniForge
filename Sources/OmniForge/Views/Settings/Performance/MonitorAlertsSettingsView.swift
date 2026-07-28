import SwiftUI

struct MonitorAlertsSettingsView: View {
    @ObservedObject var preferences: MonitorPreferences
    let notificationError: String?
    let strings: Strings
    var isMonitorEnabled: Bool = true

    var body: some View {
        Form {
            if let error = notificationError {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(.red)
                    Text(error).foregroundColor(.red).font(.caption)
                }
            }
            Section(strings.alertsSettingsTitle) {
                Toggle(strings.alertsCpu, isOn: alertBinding(\.cpuEnabled))
                Toggle(strings.alertsCpuTemperature, isOn: alertBinding(\.cpuTemperatureEnabled))
                Toggle(strings.alertsMemory, isOn: alertBinding(\.memoryEnabled))
                Toggle(strings.alertsDisk, isOn: alertBinding(\.diskEnabled))
                Toggle(strings.alertsBattery, isOn: alertBinding(\.batteryEnabled))
            }
            .disabled(!isMonitorEnabled)
        }
        .settingsPageStyle()
    }

    private func alertBinding(_ keyPath: WritableKeyPath<MonitorAlertConfiguration, Bool>) -> Binding<Bool> {
        Binding(
            get: {
                isMonitorEnabled && preferences.configuration.alert[keyPath: keyPath]
            },
            set: { enabled in
                guard isMonitorEnabled else { return }
                preferences.update { $0.alert[keyPath: keyPath] = enabled }
            }
        )
    }
}
