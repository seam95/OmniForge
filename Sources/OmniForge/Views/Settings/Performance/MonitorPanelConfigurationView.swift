import SwiftUI

struct MonitorPanelConfigurationRow: Identifiable, Equatable {
    let id: String
    let section: MonitorSection
    let title: String
    let isVisible: Bool
}

enum MonitorPanelConfigurationState {
    static func rows(
        configuration: MonitorConfiguration,
        strings: Strings
    ) -> [MonitorPanelConfigurationRow] {
        MonitorSection.allCases.map { section in
            MonitorPanelConfigurationRow(
                id: "performance.section.\(section.rawValue)",
                section: section,
                title: title(section, strings: strings),
                isVisible: configuration.visibleSections.contains(section)
            )
        }
    }

    private static func title(_ section: MonitorSection, strings: Strings) -> String {
        switch section {
        case .system: return strings.monitorSectionSystem
        case .network: return strings.monitorSectionNetwork
        case .disk: return strings.monitorSectionDisk
        case .power: return strings.monitorSectionPower
        case .fan: return strings.monitorSectionFan
        }
    }
}

/// 监控面板分区可见性（固定顺序，仅 Section，由外层 Form 承载）。
struct MonitorPanelConfigurationView: View {
    @ObservedObject var preferences: MonitorPreferences
    let strings: Strings
    var isMonitorEnabled: Bool = true

    var body: some View {
        Section(strings.monitorPanelSectionsTitle) {
            ForEach(MonitorPanelConfigurationState.rows(
                configuration: preferences.configuration,
                strings: strings
            )) { row in
                Toggle(row.title, isOn: Binding(
                    get: { isMonitorEnabled && row.isVisible },
                    set: { enabled in
                        guard isMonitorEnabled else { return }
                        preferences.update { config in
                            if enabled {
                                config.visibleSections.insert(row.section)
                            } else if config.visibleSections.count > 1 {
                                config.visibleSections.remove(row.section)
                            }
                        }
                    }
                ))
                .accessibilityIdentifier(SettingsAccessibilityID.performanceSectionEnabled(row.section))
            }
        }
        .disabled(!isMonitorEnabled)
    }
}
