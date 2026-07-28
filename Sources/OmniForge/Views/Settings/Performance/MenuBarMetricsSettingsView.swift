import SwiftUI
import AppKit

struct MenuBarMetricsSettingsView: View {
    @ObservedObject var preferences: MonitorPreferences
    /// 直接观察 monitor，确保采样 tick 时预览随 snapshot 刷新
    @ObservedObject var monitor: SystemMonitorManager
    let strings: Strings
    var isMonitorEnabled: Bool = true

    private var isMenuBarEnabled: Bool {
        isMonitorEnabled && !preferences.configuration.enabledMenuBarMetrics.isEmpty
    }

    var body: some View {
        Form {
            Section {
                Toggle(strings.menubarSettingsEnable, isOn: Binding(
                    get: { isMenuBarEnabled },
                    set: { enabled in
                        guard isMonitorEnabled else { return }
                        preferences.update { config in
                            if enabled {
                                if config.enabledMenuBarMetrics.isEmpty {
                                    // 默认打开 CPU；用户可再勾选其它指标
                                    config.enabledMenuBarMetrics = [.cpu]
                                }
                            } else {
                                config.enabledMenuBarMetrics = []
                            }
                        }
                    }
                ))
                .disabled(!isMonitorEnabled)
                .accessibilityIdentifier(SettingsAccessibilityID.menuBarEnabled.rawValue)
            }

            Section(strings.menubarSettingsPreview) {
                previewImage
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .padding(.vertical, 4)
                    .accessibilityIdentifier(SettingsAccessibilityID.menuBarPreview.rawValue)
            }
            .disabled(!isMenuBarEnabled)

            Section(strings.menubarSettingsTitle) {
                ForEach(preferences.configuration.menuBarMetricOrder, id: \.self) { metric in
                    HStack {
                        Toggle(metric.title(in: strings), isOn: Binding(
                            get: {
                                isMenuBarEnabled
                                    && preferences.configuration.enabledMenuBarMetrics.contains(metric)
                            },
                            set: { enabled in
                                guard isMenuBarEnabled else { return }
                                preferences.update { config in
                                    if enabled {
                                        config.enabledMenuBarMetrics.insert(metric)
                                    } else {
                                        config.enabledMenuBarMetrics.remove(metric)
                                    }
                                }
                            }
                        ))
                        .accessibilityIdentifier(SettingsAccessibilityID.menuBarMetricEnabled(metric))
                        Spacer()
                        Button(strings.settingsMoveUp) {
                            move(metric, delta: -1)
                        }
                        .disabled(!isMenuBarEnabled || preferences.configuration.menuBarMetricOrder.first == metric)
                        Button(strings.settingsMoveDown) {
                            move(metric, delta: 1)
                        }
                        .disabled(!isMenuBarEnabled || preferences.configuration.menuBarMetricOrder.last == metric)
                    }
                }
            }
            .disabled(!isMenuBarEnabled)

            Section(strings.menubarSettingsSpacing) {
                Picker(strings.menubarSettingsSpacing, selection: Binding(
                    get: { preferences.configuration.menuBarSpacing },
                    set: { spacing in
                        preferences.update { $0.menuBarSpacing = spacing }
                    }
                )) {
                    Text(strings.menubarSettingsCompact).tag(MenuBarMetricSpacing.compact)
                    Text(strings.menubarSettingsStandard).tag(MenuBarMetricSpacing.standard)
                }
                .accessibilityIdentifier(SettingsAccessibilityID.menuBarSpacing.rawValue)

                Picker(strings.menubarSettingsMemoryStyle, selection: Binding(
                    get: { preferences.configuration.menuBarMemoryStyle },
                    set: { style in
                        preferences.update { $0.menuBarMemoryStyle = style }
                    }
                )) {
                    Text(strings.menubarSettingsMemoryPercent).tag(MemoryMenuBarStyle.percent)
                    Text(strings.menubarSettingsMemoryUsed).tag(MemoryMenuBarStyle.used)
                    Text(strings.menubarSettingsMemoryPressure).tag(MemoryMenuBarStyle.pressure)
                }
                .accessibilityIdentifier(SettingsAccessibilityID.menuBarMemoryStyle.rawValue)

                Toggle(strings.menubarSettingsNetworkUploadFirst, isOn: Binding(
                    get: { isMenuBarEnabled && preferences.configuration.networkUploadFirst },
                    set: { value in
                        guard isMenuBarEnabled else { return }
                        preferences.update { $0.networkUploadFirst = value }
                    }
                ))
                .accessibilityIdentifier(SettingsAccessibilityID.menuBarNetworkUploadFirst.rawValue)

                Toggle(strings.menubarSettingsCombineTemperatures, isOn: Binding(
                    get: { isMenuBarEnabled && preferences.configuration.combineTemperatures },
                    set: { value in
                        guard isMenuBarEnabled else { return }
                        preferences.update { $0.combineTemperatures = value }
                    }
                ))
                .accessibilityIdentifier(SettingsAccessibilityID.menuBarCombineTemperatures.rawValue)

                Toggle(strings.menubarSettingsSeparateStatusItems, isOn: Binding(
                    get: { isMenuBarEnabled && preferences.configuration.separateStatusItems },
                    set: { value in
                        guard isMenuBarEnabled else { return }
                        preferences.update { $0.separateStatusItems = value }
                    }
                ))
                .accessibilityIdentifier(SettingsAccessibilityID.menuBarSeparateItems.rawValue)

                Toggle(strings.menubarSettingsHideMainIcon, isOn: Binding(
                    get: { isMenuBarEnabled && preferences.configuration.hideMainIconWithMetrics },
                    set: { value in
                        guard isMenuBarEnabled else { return }
                        preferences.update { $0.hideMainIconWithMetrics = value }
                    }
                ))
                .accessibilityIdentifier(SettingsAccessibilityID.menuBarHideMainIcon.rawValue)
            }
            .disabled(!isMenuBarEnabled)
        }
        .settingsPageStyle()
    }

    // MARK: - 预览

    @ViewBuilder
    private var previewImage: some View {
        let metrics = isMenuBarEnabled
            ? preferences.configuration.menuBarMetricOrder.filter {
                preferences.configuration.enabledMenuBarMetrics.contains($0)
            }
            : []
        if metrics.isEmpty {
            Text("—")
                .foregroundStyle(.secondary)
        } else {
            let title = MenuBarMetricRenderer.attributedTitle(
                for: monitor.snapshot,
                metrics: metrics,
                configuration: preferences.configuration
            )
            Image(nsImage: renderPreviewImage(from: title))
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 28)
                .accessibilityHidden(true)
        }
    }

    private func renderPreviewImage(from title: NSAttributedString) -> NSImage {
        let size = title.size()
        let width = max(1, ceil(size.width) + 4)
        let height = max(1, ceil(size.height) + 4)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        title.draw(at: NSPoint(x: 2, y: 2))
        image.unlockFocus()
        return image
    }

    private func move(_ metric: MenuBarMetric, delta: Int) {
        preferences.update { config in
            guard let index = config.menuBarMetricOrder.firstIndex(of: metric) else { return }
            let target = index + delta
            guard config.menuBarMetricOrder.indices.contains(target) else { return }
            config.menuBarMetricOrder.swapAt(index, target)
        }
    }
}
