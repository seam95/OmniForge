import SwiftUI

/// 风扇设置页：特权 Helper 安装管理。
/// 性能模式与手动调速偏好随协调器（后续阶段）并入本页。
struct FanSettingsView: View {
    let strings: Strings

    private enum HelperState: Equatable {
        case unknown
        case notRegistered
        case registeredVersionOK
        case registeredVersionMismatch
        case registerFailed(String)
    }

    @State private var state: HelperState = .unknown
    @State private var isBusy = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
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
        .settingsPageStyle()
        .onAppear(perform: refreshStatus)
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
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: - 动作

    private func refreshStatus() {
        guard FanHelperInstaller.isRegistered() else {
            state = .notRegistered
            return
        }
        state = .unknown
        // XPC reply 在后台队列回调，状态回写须回主线程
        FanHelperInstaller.checkVersion(client: FanHelperClient()) { matched in
            DispatchQueue.main.async {
                state = (matched == true) ? .registeredVersionOK : .registeredVersionMismatch
            }
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
            state = .registerFailed(error.localizedDescription)
        }
    }

    private func uninstall() {
        isBusy = true
        try? FanHelperInstaller.unregister()
        isBusy = false
        state = .notRegistered
    }
}
