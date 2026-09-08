import SwiftUI

/// 风扇设置页：无风扇机型提示 / 特权 Helper 安装管理 + 性能模式偏好。
struct FanSettingsView: View {
    /// 性能偏好注入 — nil（功能未接线）时只显示 Helper 管理区
    var preferences: FanPreferences? = nil
    var fanControl: FanControlCoordinator? = nil
    let strings: Strings

    private enum HelperState: Equatable {
        case unknown
        case notRegistered
        /// 已登记待用户批准：register() 报 code=1 后系统在等通知/系统设置里的「允许」
        case awaitingApproval
        case registeredVersionOK
        case registeredVersionMismatch
        case registerFailed(String)
    }

    @State private var state: HelperState = .unknown
    @State private var isBusy = false

    /// awaitingApproval 期间轮询注册状态：用户在通知/系统设置批准后 daemon 即刻生效，
    /// 无需重启 app；发现 enabled 后转入版本协商并自然停止轮询
    private let approvalPoller = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if fanControl?.hasFans == false {
                // 无风扇机型：控制组件无意义，隐藏安装与偏好入口
                Section {
                    Label(strings.fanControlUnavailableOnFanless, systemImage: "fanblades.slash")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text(strings.fanMonitoringStillWorks)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                helperSection
                if let preferences {
                    preferencesSection(preferences)
                }
            }
        }
        .settingsPageStyle()
        .onAppear(perform: refreshStatus)
        .onReceive(approvalPoller) { _ in
            guard state == .awaitingApproval else { return }
            // 拒绝/撤销会把状态打回未注册，轮询里全量分流可一并收敛
            refreshStatus()
        }
    }

    // MARK: - Helper 管理

    private var helperSection: some View {
        Section {
            statusRow

            if state == .notRegistered || isVersionMismatch {
                Button(action: install) {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(strings.fanSettingsHelperInstall)
                    }
                }
                .disabled(isBusy)
            }
            if state == .awaitingApproval {
                Button(strings.fanSettingsHelperOpenApprovalSettings) {
                    FanHelperInstaller.openApprovalSettings()
                }
            }
            if isRegisteredState {
                Button(action: uninstall) {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(strings.fanSettingsHelperUninstall)
                    }
                }
                .disabled(isBusy)
            }
        } header: {
            Text(strings.fanSettingsHelperSection)
        } footer: {
            Text(strings.fanSettingsHelperFooter)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isRegisteredState: Bool {
        state == .registeredVersionOK || state == .registeredVersionMismatch
    }

    private var isVersionMismatch: Bool {
        state == .registeredVersionMismatch
    }

    private var statusRow: some View {
        HStack {
            Text(strings.fanSettingsHelperStatusTitle)
            Spacer()
            switch state {
            case .unknown:
                ProgressView()
                    .controlSize(.small)
            case .notRegistered:
                Text(strings.fanSettingsHelperStatusNotInstalled)
                    .foregroundStyle(.secondary)
            case .awaitingApproval:
                VStack(alignment: .trailing, spacing: 2) {
                    Label(
                        strings.fanSettingsHelperStatusAwaitingApproval,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    Text(strings.fanSettingsHelperAwaitingApprovalHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(3)
                }
            case .registeredVersionOK:
                Label(strings.fanSettingsHelperStatusReady, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .registeredVersionMismatch:
                Label(strings.fanSettingsHelperStatusVersionMismatch, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .registerFailed(let message):
                VStack(alignment: .trailing, spacing: 2) {
                    Text(strings.fanSettingsHelperStatusRegisterFailed)
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
    }

    // MARK: - 性能偏好

    private func preferencesSection(_ preferences: FanPreferences) -> some View {
        Section {
            Picker(strings.fanLevelLabel, selection: Binding(
                get: { preferences.configuration.performanceLevel },
                set: { level in
                    preferences.update { $0.performanceLevel = level }
                }
            )) {
                Text(strings.fanLevelLow).tag(FanCurve.Level.low)
                Text(strings.fanLevelMedium).tag(FanCurve.Level.medium)
                Text(strings.fanLevelHigh).tag(FanCurve.Level.high)
                Text(strings.fanLevelMax).tag(FanCurve.Level.max)
            }

            Toggle(strings.fanSettingsBatterySaver, isOn: Binding(
                get: { preferences.configuration.batterySaverEnabled },
                set: { enabled in
                    preferences.update { $0.batterySaverEnabled = enabled }
                }
            ))
            if preferences.configuration.batterySaverEnabled {
                Stepper(
                    "\(strings.fanSettingsBatterySaverThreshold): \(preferences.configuration.batterySaverThreshold)%",
                    value: Binding(
                        get: { preferences.configuration.batterySaverThreshold },
                        set: { value in
                            preferences.update { $0.batterySaverThreshold = value }
                        }
                    ),
                    in: 5...50,
                    step: 5
                )
                Toggle(strings.fanSettingsForceOnBattery, isOn: Binding(
                    get: { preferences.configuration.forcePerformanceOnBattery },
                    set: { enabled in
                        preferences.update { $0.forcePerformanceOnBattery = enabled }
                    }
                ))
            }

            Toggle(strings.fanSettingsKeepOnScreenSleep, isOn: Binding(
                get: { preferences.configuration.keepFansOnScreenSleep },
                set: { enabled in
                    preferences.update { $0.keepFansOnScreenSleep = enabled }
                }
            ))

            if let fanControl, fanControl.batterySaverSuppressed {
                Label(strings.fanBatterySaverNotice, systemImage: "battery.25")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(strings.fanSettingsPreferencesSection)
        }
    }

    // MARK: - 动作

    private func refreshStatus() {
        switch FanHelperInstaller.registrationStatus() {
        case .enabled:
            state = .unknown
            // XPC reply 在后台队列回调，状态回写须回主线程；
            // fetchVersion 带 3s 超时，daemon 未运行时会回调 nil（不再悬挂转圈）
            FanHelperInstaller.checkVersion(client: FanHelperClient()) { matched in
                DispatchQueue.main.async {
                    state = (matched == true) ? .registeredVersionOK : .registeredVersionMismatch
                }
            }
        case .requiresApproval:
            state = .awaitingApproval
        default:
            state = .notRegistered
        }
    }

    private func install() {
        isBusy = true
        // 版本不匹配时的重装：先注销旧 daemon
        if isVersionMismatch {
            try? FanHelperInstaller.unregister()
        }
        do {
            try FanHelperInstaller.register()
            // daemon 拉起需要短暂时间，延迟后核对版本
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                isBusy = false
                refreshStatus()
            }
        } catch {
            isBusy = false
            // 首次注册 macOS 会抛 code=1 并弹通知等批准 — 以事后 status 分流，
            // 只有真正未登记才算失败（否则用户批准后 UI 卡死在"失败"直到重启）
            switch FanHelperInstaller.outcome(
                afterRegisterError: error,
                status: FanHelperInstaller.registrationStatus()
            ) {
            case .enabled:
                refreshStatus()
            case .awaitingApproval:
                state = .awaitingApproval
            case .failed(let message):
                state = .registerFailed(message)
            }
        }
    }

    private func uninstall() {
        isBusy = true
        try? FanHelperInstaller.unregister()
        isBusy = false
        state = .notRegistered
    }
}
