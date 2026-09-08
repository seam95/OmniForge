import SwiftUI

/// 性能设置聚合页：监控 / 菜单栏 / 告警 三段。
struct PerformanceSettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var runtime = FeatureRuntime.shared
    @State private var section: PerformanceSettingsSection = .monitor

    private var isInstalled: Bool {
        runtime.isAvailable(.systemMonitor)
    }

    private var isMonitorEnabled: Bool {
        isInstalled && (state.monitorPreferences?.configuration.isEnabled == true)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isInstalled {
                Form {
                    Section {
                        Toggle(state.l10n.s.featureHubNameSystemMonitor, isOn: Binding(
                            get: { false },
                            set: { newValue in
                                Task { @MainActor in
                                    _ = await runtime.setAvailableAsync(.systemMonitor, newValue)
                                }
                            }
                        ))
                        .accessibilityIdentifier(SettingsAccessibilityID.performanceMonitorEnabled.rawValue)
                    } footer: {
                        Text(state.l10n.s.featureHubDescSystemMonitor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .settingsPageStyle()
            } else if let preferences = state.monitorPreferences,
                      let monitor = state.monitor {
                Picker("", selection: $section) {
                    ForEach(PerformanceSettingsSection.allCases) { item in
                        Text(item.title(in: state.l10n.s)).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(SettingsAccessibilityID.performanceSegment.rawValue)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 10)

                Divider()

                Group {
                    switch section {
                    case .monitor:
                        Form {
                            Section {
                                Toggle(state.l10n.s.featureHubNameSystemMonitor, isOn: Binding(
                                    get: { true },
                                    set: { runtime.setAvailable(.systemMonitor, $0) }
                                ))
                                .accessibilityIdentifier(SettingsAccessibilityID.performanceMonitorEnabled.rawValue)
                            }
                            MonitorSettingsView(
                                preferences: preferences,
                                strings: state.l10n.s
                            )
                            MonitorPanelConfigurationView(
                                preferences: preferences,
                                strings: state.l10n.s,
                                isMonitorEnabled: isMonitorEnabled
                            )
                        }
                        .settingsPageStyle()
                    case .menuBar:
                        MenuBarMetricsSettingsView(
                            preferences: preferences,
                            monitor: monitor,
                            strings: state.l10n.s,
                            isMonitorEnabled: isMonitorEnabled
                        )
                    case .alerts:
                        MonitorAlertsSettingsView(
                            preferences: preferences,
                            notificationError: state.monitorAlerts?.lastError,
                            strings: state.l10n.s,
                            isMonitorEnabled: isMonitorEnabled
                        )
                    case .fan:
                        FanSettingsView(
                            preferences: state.fanPreferences,
                            fanControl: state.fanControl,
                            strings: state.l10n.s
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
