import SwiftUI

struct MouseSettingsSection: View {
    @ObservedObject private var runtime: FeatureRuntime
    @ObservedObject private var inverter: ScrollInverter
    @ObservedObject private var smoothScroll: SmoothScrollService
    @ObservedObject private var mouseNavigation: MouseNavigationService
    @ObservedObject private var dockClick: DockClickService

    @AppStorage(UserDefaultsKeys.scrollInverterEnabled) private var inverterEnabled = false
    @AppStorage(UserDefaultsKeys.smoothScrollEnabled) private var smoothScrollEnabled = false
    @AppStorage(UserDefaultsKeys.smoothScrollStep) private var smoothScrollStep = SmoothScrollSupport.defaultStep
    @AppStorage(UserDefaultsKeys.mouseNavigationEnabled) private var mouseNavigationEnabled = false
    @AppStorage(UserDefaultsKeys.dockClickMinimize) private var dockClickMinimize = false
    @AppStorage(UserDefaultsKeys.dockClickCycleWindows) private var dockClickCycleWindows = false

    let strings: Strings

    init(
        strings: Strings,
        runtime: FeatureRuntime = .shared,
        inverter: ScrollInverter = .shared,
        smoothScroll: SmoothScrollService = .shared,
        mouseNavigation: MouseNavigationService = .shared,
        dockClick: DockClickService = .shared
    ) {
        self.strings = strings
        self.runtime = runtime
        self.inverter = inverter
        self.smoothScroll = smoothScroll
        self.mouseNavigation = mouseNavigation
        self.dockClick = dockClick
    }

    var body: some View {
        Group {
            if runtime.isAvailable(.mouse) {
                Section(strings.scrollSection) {
                    Toggle(isOn: $inverterEnabled) {
                        InfoHintLabel(
                            strings.invertMouseScroll,
                            hint: strings.invertMouseScrollCaption + "\n" + strings.scrollTrackpadNote
                        )
                    }
                    .accessibilityIdentifier(SettingsAccessibilityID.mouseScrollInverterEnabled.rawValue)
                    .onChange(of: inverterEnabled) { _, _ in inverter.syncWithPreferences() }
                    FeatureRunStateRow(state: inverter.runState, strings: strings, retry: inverter.retry)
                }

                Section(strings.smoothScrollName) {
                    Toggle(isOn: $smoothScrollEnabled) {
                        InfoHintLabel(strings.smoothScrollName, hint: strings.smoothScrollCaption)
                    }
                    .accessibilityIdentifier(SettingsAccessibilityID.mouseSmoothScrollEnabled.rawValue)
                    .onChange(of: smoothScrollEnabled) { _, _ in smoothScroll.syncWithPreferences() }
                    if smoothScrollEnabled {
                        HStack {
                            Slider(
                                value: smoothScrollStepBinding,
                                in: Double(SmoothScrollSupport.stepRange.lowerBound)...Double(SmoothScrollSupport.stepRange.upperBound),
                                step: 10
                            ) {
                                Text(strings.smoothScrollStepLabel)
                            }
                            .accessibilityIdentifier(SettingsAccessibilityID.mouseSmoothScrollStep.rawValue)
                            Text("\(SmoothScrollSupport.sanitizedStep(smoothScrollStep))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                    FeatureRunStateRow(state: smoothScroll.runState, strings: strings, retry: smoothScroll.retry)
                }

                Section(strings.mouseNavigationSection) {
                    Toggle(isOn: $mouseNavigationEnabled) {
                        InfoHintLabel(strings.mouseNavigationEnable, hint: strings.mouseNavigationCaption)
                    }
                    .accessibilityIdentifier(SettingsAccessibilityID.mouseNavigationEnabled.rawValue)
                    .onChange(of: mouseNavigationEnabled) { _, _ in mouseNavigation.syncWithPreferences() }
                    FeatureRunStateRow(
                        state: mouseNavigation.runState,
                        strings: strings,
                        retry: mouseNavigation.retry
                    )
                }

                Section(strings.dockClickSection) {
                    Toggle(isOn: $dockClickMinimize) {
                        InfoHintLabel(strings.dockClickMinimize, hint: strings.dockClickMinimizeCaption)
                    }
                    .accessibilityIdentifier(SettingsAccessibilityID.mouseDockClickMinimize.rawValue)
                    .onChange(of: dockClickMinimize) { _, _ in dockClick.syncWithPreferences() }
                    Toggle(isOn: $dockClickCycleWindows) {
                        InfoHintLabel(strings.dockClickCycleWindows, hint: strings.dockClickCycleWindowsCaption)
                    }
                    .accessibilityIdentifier(SettingsAccessibilityID.mouseDockClickCycle.rawValue)
                    .onChange(of: dockClickCycleWindows) { _, _ in dockClick.syncWithPreferences() }
                    FeatureRunStateRow(state: dockClick.runState, strings: strings, retry: dockClick.retry)
                }
            }
        }
    }

    private var smoothScrollStepBinding: Binding<Double> {
        Binding(
            get: { Double(SmoothScrollSupport.sanitizedStep(smoothScrollStep)) },
            set: { smoothScrollStep = Int($0) }
        )
    }
}
