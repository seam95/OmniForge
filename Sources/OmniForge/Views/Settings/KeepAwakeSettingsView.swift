import ApplicationServices
import SwiftUI

/// 保持唤醒设置页：会话 / 电量 / 菜单栏 / 快捷键 / 微动 / 合盖 / 诊断。
struct KeepAwakeSettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var runtime = FeatureRuntime.shared
    private let userDefaults: UserDefaults

    @State private var configError: String?
    @State private var isAuthorizing = false
    @State private var authorizationMessage: String?
    @State private var capability: ClamshellCapability = .checking
    @State private var showInstallDisclosure = false
    @State private var showRemoveConfirmation = false

    private var s: Strings { state.l10n.s }

    init(state: AppState, userDefaults: UserDefaults = .standard) {
        self.state = state
        self.userDefaults = userDefaults
    }

    var body: some View {
        Form {
            if let configError {
                Section {
                    Text(configError)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            sessionSection
            batterySection
            menuBarSection
            shortcutSection
            pointerSection
            clamshellSection
            diagnosticsSection
        }
        .settingsPageStyle()
        .task {
            await refreshCapability()
        }
        .alert(s.keepAwakeAuthDisclosureTitle, isPresented: $showInstallDisclosure) {
            Button(s.keepAwakeAuthCancel, role: .cancel) {}
            Button(s.keepAwakeAuthContinue) {
                Task { await performInstallAuthorization() }
            }
        } message: {
            Text(s.keepAwakeAuthDisclosureBody)
        }
        .alert(s.keepAwakeAuthRemoveTitle, isPresented: $showRemoveConfirmation) {
            Button(s.keepAwakeAuthCancel, role: .cancel) {}
            Button(s.keepAwakeAuthRemove, role: .destructive) {
                Task { await performRemoveAuthorization() }
            }
        } message: {
            Text(s.keepAwakeAuthRemoveBody)
        }
    }

    // MARK: - Sections

    private var sessionSection: some View {
        Section(s.keepAwakeSectionSession) {
            Picker(s.keepAwakeDefaultDuration, selection: durationBinding) {
                Text(s.keepAwakeDurationIndefinite).tag(0)
                Text(String(format: s.keepAwakeDurationMinutesFormat, 15)).tag(15)
                Text(String(format: s.keepAwakeDurationMinutesFormat, 30)).tag(30)
                Text(String(format: s.keepAwakeDurationHoursFormat, 1)).tag(60)
                Text(String(format: s.keepAwakeDurationHoursFormat, 2)).tag(120)
                Text(String(format: s.keepAwakeDurationHoursFormat, 4)).tag(240)
                Text(String(format: s.keepAwakeDurationHoursFormat, 8)).tag(480)
            }
            .accessibilityIdentifier(SettingsAccessibilityID.keepAwakeDuration.rawValue)
            Toggle(s.keepAwakeAutoStart, isOn: boolBinding(UserDefaultsKeys.keepAwakeAutoStart, default: false))
                .accessibilityIdentifier(SettingsAccessibilityID.keepAwakeAutoStart.rawValue)
        }
    }

    private var batterySection: some View {
        Section(s.keepAwakeSectionBattery) {
            Picker(s.keepAwakeBatteryThreshold, selection: batteryBinding) {
                Text(s.keepAwakeBatteryOff).tag(0)
                Text(String(format: s.keepAwakeBatteryPercentFormat, 5)).tag(5)
                Text(String(format: s.keepAwakeBatteryPercentFormat, 10)).tag(10)
                Text(String(format: s.keepAwakeBatteryPercentFormat, 15)).tag(15)
                Text(String(format: s.keepAwakeBatteryPercentFormat, 20)).tag(20)
            }
            .accessibilityIdentifier(SettingsAccessibilityID.keepAwakeBatteryThreshold.rawValue)
            Text(s.keepAwakeBatteryCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var menuBarSection: some View {
        Section(s.keepAwakeSectionMenuBar) {
            Toggle(s.keepAwakeShowCountdown, isOn: boolBinding(UserDefaultsKeys.keepAwakeShowCountdown, default: false))
                .accessibilityIdentifier(SettingsAccessibilityID.keepAwakeCountdown.rawValue)
        }
    }

    private var shortcutSection: some View {
        Section(s.keepAwakeSectionShortcut) {
            Toggle(s.keepAwakeEnableShortcut, isOn: boolBinding(UserDefaultsKeys.keepAwakeShortcutEnabled, default: true))
                .accessibilityIdentifier(SettingsAccessibilityID.keepAwakeHotkeyEnabled.rawValue)
            if let hotkeyManager = runtime.manager(for: .keepAwake, as: KeepAwakeHotkeyManager.self) {
                KeepAwakeHotkeyRecorderView(
                    state: KeepAwakeHotkeyRecorderState(
                        initial: hotkeyManager.hotkey,
                        apply: { hotkeyManager.updateHotkey($0) }
                    ),
                    strings: s
                )
                if let error = hotkeyManager.registrationError {
                    Text(String(describing: error))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else {
                Text(s.keepAwakeHotkeyManagerMissing)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pointerSection: some View {
        Section(s.keepAwakeSectionPointer) {
            Toggle(s.keepAwakeEnableJiggle, isOn: boolBinding(UserDefaultsKeys.keepAwakeMouseJiggleEnabled, default: false))
                .accessibilityIdentifier(SettingsAccessibilityID.keepAwakePointerJiggleEnabled.rawValue)
            Picker(s.keepAwakeJiggleInterval, selection: pointerIntervalBinding) {
                Text(String(format: s.keepAwakeDurationMinutesFormat, 1)).tag(1)
                Text(String(format: s.keepAwakeDurationMinutesFormat, 2)).tag(2)
                Text(String(format: s.keepAwakeDurationMinutesFormat, 5)).tag(5)
                Text(String(format: s.keepAwakeDurationMinutesFormat, 10)).tag(10)
                Text(String(format: s.keepAwakeDurationMinutesFormat, 15)).tag(15)
            }
            .accessibilityIdentifier(SettingsAccessibilityID.keepAwakePointerJiggleInterval.rawValue)
            Text(s.keepAwakeJiggleCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(s.keepAwakeRequestAccessibility) {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
        }
    }

    private var clamshellSection: some View {
        Section(s.keepAwakeSectionClamshell) {
            Toggle(
                s.keepAwakePreferClamshell,
                isOn: clamshellPreferredBinding
            )
            .accessibilityIdentifier(SettingsAccessibilityID.keepAwakeClamshellPreferred.rawValue)
            Text(s.keepAwakeAuthDisclosureBody)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(s.keepAwakeCapabilityPrefix)：\(capabilitySummary)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message = authorizationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(isAuthorizing ? s.keepAwakeMenuProcessing : s.keepAwakeConfigureAuth) {
                    showInstallDisclosure = true
                }
                .disabled(isAuthorizing)
                Button(s.keepAwakeRemoveAuth) {
                    showRemoveConfirmation = true
                }
                .disabled(isAuthorizing)
                Button(s.keepAwakeRefreshStatus) {
                    Task { await refreshCapability() }
                }
                .disabled(isAuthorizing)
            }
        }
    }

    private var diagnosticsSection: some View {
        Section(s.keepAwakeSectionDiagnostics) {
            if let manager = state.keepAwakeManager {
                Text(KeepAwakeDiagnosticText.session(manager.state, strings: s))
                Text(KeepAwakeDiagnosticText.clamshell(manager.clamshellState, strings: s))
                if let err = manager.lastOperationError {
                    Text(String(format: s.keepAwakeDiagErrorFormat, String(describing: err)))
                        .foregroundStyle(.red)
                }
            } else {
                Text(s.keepAwakeDiagManagerMissing)
                    .foregroundStyle(.secondary)
            }
            if let recovery = state.clamshellRecoveryCoordinator {
                Text(KeepAwakeDiagnosticText.recovery(recovery.state, strings: s))
            }
        }
    }

    // MARK: - Capability summary

    private var capabilitySummary: String {
        switch capability {
        case .checking: return s.keepAwakeCapabilityChecking
        case .unsupported(let reason):
            return String(format: s.keepAwakeCapabilityUnsupportedFormat, reason)
        case .needsAuthorization: return s.keepAwakeCapabilityNeedsAuth
        case .ready: return s.keepAwakeCapabilityReady
        case .conflict(let reason):
            return String(format: s.keepAwakeCapabilityConflictFormat, reason)
        case .invalidAuthorization(let reason):
            return String(format: s.keepAwakeCapabilityInvalidFormat, reason)
        }
    }

    // MARK: - Bindings

    private var durationBinding: Binding<Int> {
        Binding(
            get: {
                if userDefaults.object(forKey: UserDefaultsKeys.keepAwakeDefaultDurationMinutes) == nil {
                    return 0
                }
                return userDefaults.integer(forKey: UserDefaultsKeys.keepAwakeDefaultDurationMinutes)
            },
            set: { newValue in
                do {
                    _ = try KeepAwakeDuration.parse(newValue)
                    userDefaults.set(newValue, forKey: UserDefaultsKeys.keepAwakeDefaultDurationMinutes)
                    configError = nil
                } catch {
                    configError = String(describing: error)
                }
            }
        )
    }

    private var batteryBinding: Binding<Int> {
        Binding(
            get: {
                if userDefaults.object(forKey: UserDefaultsKeys.keepAwakeBatteryLimitPercent) == nil {
                    return 10
                }
                return userDefaults.integer(forKey: UserDefaultsKeys.keepAwakeBatteryLimitPercent)
            },
            set: { newValue in
                do {
                    _ = try KeepAwakeBatteryLimit.parse(newValue)
                    userDefaults.set(newValue, forKey: UserDefaultsKeys.keepAwakeBatteryLimitPercent)
                    configError = nil
                } catch {
                    configError = String(describing: error)
                }
            }
        )
    }

    private var pointerIntervalBinding: Binding<Int> {
        Binding(
            get: {
                if userDefaults.object(forKey: UserDefaultsKeys.keepAwakeMouseJiggleIntervalMinutes) == nil {
                    return 5
                }
                return userDefaults.integer(forKey: UserDefaultsKeys.keepAwakeMouseJiggleIntervalMinutes)
            },
            set: { newValue in
                do {
                    _ = try KeepAwakePointerInterval.parse(newValue)
                    userDefaults.set(newValue, forKey: UserDefaultsKeys.keepAwakeMouseJiggleIntervalMinutes)
                    configError = nil
                } catch {
                    configError = String(describing: error)
                }
            }
        )
    }

    private var clamshellPreferredBinding: Binding<Bool> {
        Binding(
            get: {
                if userDefaults.object(forKey: UserDefaultsKeys.keepAwakeClamshellPreferred) == nil {
                    return false
                }
                return userDefaults.bool(forKey: UserDefaultsKeys.keepAwakeClamshellPreferred)
            },
            set: { newValue in
                userDefaults.set(newValue, forKey: UserDefaultsKeys.keepAwakeClamshellPreferred)
                Task {
                    await state.keepAwakeManager?.setClamshellPreferred(newValue)
                }
            }
        )
    }

    private func boolBinding(_ key: String, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: {
                if userDefaults.object(forKey: key) == nil { return defaultValue }
                return userDefaults.bool(forKey: key)
            },
            set: { userDefaults.set($0, forKey: key) }
        )
    }

    // MARK: - Authorization

    private func refreshCapability() async {
        if let manager = state.keepAwakeManager {
            capability = await manager.refreshClamshellCapability()
        } else {
            capability = .unsupported(reason: s.keepAwakeDiagManagerMissing)
        }
    }

    private func performInstallAuthorization() async {
        guard !isAuthorizing else { return }
        isAuthorizing = true
        defer { isAuthorizing = false }

        // Manager 优先；Feature unavailable 时仍可通过已注入 controller 的 Manager 边界。
        guard let manager = state.keepAwakeManager else {
            authorizationMessage = s.keepAwakeAuthManagerMissingInstall
            return
        }
        do {
            try await manager.installClamshellAuthorization()
            authorizationMessage = s.keepAwakeAuthInstallSuccess
            await refreshCapability()
            // 若偏好已开且会话 active，尝试启用合盖。
            if userDefaults.bool(forKey: UserDefaultsKeys.keepAwakeClamshellPreferred) {
                await manager.setClamshellPreferred(true)
            }
        } catch let error as KeepAwakeError {
            authorizationMessage = error.localizedDescriptionText(strings: s)
        } catch {
            authorizationMessage = String(describing: error)
        }
    }

    private func performRemoveAuthorization() async {
        guard !isAuthorizing else { return }
        isAuthorizing = true
        defer { isAuthorizing = false }

        do {
            if let manager = state.keepAwakeManager {
                try await manager.removeClamshellAuthorization()
            } else if let recovery = state.clamshellRecoveryCoordinator {
                // Feature unavailable 时走始终装载的 RecoveryCoordinator。
                try await recovery.removeAuthorization()
            } else {
                authorizationMessage = s.keepAwakeAuthNoRemoveEntry
                return
            }
            authorizationMessage = s.keepAwakeAuthRemoveSuccess
            await refreshCapability()
        } catch let error as KeepAwakeError {
            authorizationMessage = error.localizedDescriptionText(strings: s)
        } catch {
            authorizationMessage = String(describing: error)
        }
    }
}

enum KeepAwakeDiagnosticText {
    static func make(
        session: KeepAwakeSessionState,
        clamshell: ClamshellState,
        recovery: ClamshellRecoveryUIState,
        strings: Strings
    ) -> String {
        [
            self.session(session, strings: strings),
            self.clamshell(clamshell, strings: strings),
            self.recovery(recovery, strings: strings),
        ].joined(separator: "\n")
    }

    static func session(_ state: KeepAwakeSessionState, strings: Strings) -> String {
        let value: String
        switch state {
        case .inactive: value = strings.keepAwakeStatusNormalSleep
        case .activating: value = strings.keepAwakeStatusStarting
        case let .active(endDate):
            value = endDate == nil
                ? strings.keepAwakeStatusActiveIndefinite
                : strings.keepAwakeStatusActiveTimed
        case .deactivating: value = strings.keepAwakeStatusStopping
        case .cleanupRequired: value = strings.keepAwakeStatusCleanupRequired
        }
        return String(format: strings.keepAwakeDiagSessionFormat, value)
    }

    static func clamshell(_ state: ClamshellState, strings: Strings) -> String {
        switch state {
        case .off:
            return String(format: strings.keepAwakeDiagClamshellFormat, strings.keepAwakeBatteryOff)
        case .checking: return strings.keepAwakeClamshellChecking
        case .authorizing: return strings.keepAwakeClamshellAuthorizing
        case .enabling: return strings.keepAwakeClamshellEnabling
        case .active: return strings.keepAwakeClamshellActive
        case .restoring: return strings.keepAwakeClamshellRestoring
        case .conflict: return strings.keepAwakeClamshellConflict
        case .failed: return strings.keepAwakeClamshellFailed
        }
    }

    static func recovery(_ state: ClamshellRecoveryUIState, strings: Strings) -> String {
        let value: String
        switch state {
        case .idle: value = strings.keepAwakeRecoveryIdle
        case .checking: value = strings.keepAwakeRecoveryCheckingTitle
        case .recovering: value = strings.keepAwakeRecoveryRestoringTitle
        case .recovered: value = strings.keepAwakeRecoveryRecovered
        case .cleanupRequired: value = strings.keepAwakeRecoveryCleanupTitle
        case .conflict: value = strings.keepAwakeRecoveryConflictTitle
        }
        return String(format: strings.keepAwakeDiagRecoveryFormat, value)
    }
}

private extension KeepAwakeError {
    func localizedDescriptionText(strings: Strings) -> String {
        switch self {
        case .administratorAuthorizationCancelled:
            return strings.keepAwakeErrCancelled
        case .sudoersValidationFailed(let detail):
            return String(format: strings.keepAwakeErrSudoersFormat, detail)
        case .authorizationRemovalFailed(let detail):
            return String(format: strings.keepAwakeErrRemovalFormat, detail)
        case .operationInProgress:
            return strings.keepAwakeErrBusy
        case .clamshellUnsupported(let detail):
            return String(format: strings.keepAwakeErrClamshellUnsupportedFormat, detail)
        default:
            return String(describing: self)
        }
    }
}
