import SwiftUI

struct MonitorPanelConfigurationRow: Identifiable, Equatable {
    let id: String
    let section: MonitorSection
    let title: String
    let isVisible: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
}

enum MonitorPanelConfigurationState {
    static func rows(
        configuration: MonitorConfiguration,
        strings: Strings
    ) -> [MonitorPanelConfigurationRow] {
        configuration.panelSectionOrder.enumerated().map { index, section in
            MonitorPanelConfigurationRow(
                id: "performance.section.\(section.rawValue)",
                section: section,
                title: title(section, strings: strings),
                isVisible: configuration.visibleSections.contains(section),
                canMoveUp: index > 0,
                canMoveDown: index < configuration.panelSectionOrder.count - 1
            )
        }
    }

    private static func title(_ section: MonitorSection, strings: Strings) -> String {
        switch section {
        case .system: return strings.monitorSectionSystem
        case .network: return strings.monitorSectionNetwork
        case .disk: return strings.monitorSectionDisk
        case .power: return strings.monitorSectionPower
        }
    }
}

/// 监控面板分区可见性与排序（仅 Section，由外层 Form 承载）。
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
                HStack {
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
                    Spacer()
                    Button(strings.settingsMoveUp) {
                        move(row.section, delta: -1)
                    }
                    .disabled(!isMonitorEnabled || !row.canMoveUp)
                    .accessibilityIdentifier(SettingsAccessibilityID.performanceSectionMoveUp(row.section))
                    Button(strings.settingsMoveDown) {
                        move(row.section, delta: 1)
                    }
                    .disabled(!isMonitorEnabled || !row.canMoveDown)
                    .accessibilityIdentifier(SettingsAccessibilityID.performanceSectionMoveDown(row.section))
                }
            }
        }
        .disabled(!isMonitorEnabled)
    }

    private func move(_ section: MonitorSection, delta: Int) {
        preferences.update { config in
            guard let index = config.panelSectionOrder.firstIndex(of: section) else { return }
            let target = index + delta
            guard config.panelSectionOrder.indices.contains(target) else { return }
            config.panelSectionOrder.swapAt(index, target)
        }
    }
}
