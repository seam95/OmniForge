import AppKit
import KeyboardShortcuts
import SwiftUI

/// 截图设置分段（task-1 最小可编译版本，task-6 重新分区）。
struct ScreenshotSettingsSection: View {
    @ObservedObject var state: AppState
    let manager: ScreenshotFeatureManager?

    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(UserDefaultsKeys.screenshotEnabled) private var enabled = false
    @AppStorage(UserDefaultsKeys.screenshotSaveDirectoryPath) private var saveDirectoryPath =
        ScreenshotOutputConfiguration.defaultDirectoryPath
    @AppStorage(UserDefaultsKeys.screenshotFileNamePrefix) private var fileNamePrefix =
        ScreenshotOutputConfiguration.defaultPrefix
    @AppStorage(UserDefaultsKeys.recordingSaveDirectoryPath) private var recordingSaveDirectoryPath =
        RecordingOutputConfiguration.defaultDirectoryPath
    @AppStorage(UserDefaultsKeys.recordingSavePreference) private var recordingSavePreferenceRaw =
        RecordingOutputConfiguration.defaultSavePreference.rawValue

    private var strings: Strings { state.l10n.s }

    private var recordingSavePreference: Binding<RecordingSavePreference> {
        Binding(
            get: {
                RecordingSavePreference(rawValue: recordingSavePreferenceRaw)
                    ?? RecordingOutputConfiguration.defaultSavePreference
            },
            set: { recordingSavePreferenceRaw = $0.rawValue }
        )
    }

    var body: some View {
        Section(strings.featureHubNameScreenshot) {
            Toggle(strings.screenshotEnable, isOn: $enabled)
                .onChange(of: enabled) { _, _ in
                    manager?.syncWithPreferences()
                }
            Text(strings.screenshotEnableCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        permissionSection

        if let manager {
            hotkeysSection(manager)
                .disabled(!enabled)
            outputSection
                .disabled(!enabled)
            recordingSection
                .disabled(!enabled)
            if let lastError = manager.lastError, !lastError.isEmpty {
                Section {
                    Text(lastError)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var permissionSection: some View {
        Section(strings.screenshotPermissionSection) {
            HStack {
                Text(strings.featureHubPermNameScreenRecording)
                Spacer()
                Text(
                    permissions.screenRecording
                        ? strings.featureHubPermStatusGranted
                        : strings.featureHubPermStatusMissing
                )
                .foregroundStyle(permissions.screenRecording ? .green : .orange)
            }
            Text(strings.screenshotPermissionCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(strings.screenshotRequestPermission) {
                    _ = Permissions.shared.requestScreenRecordingAccess()
                }
                Button(strings.featureHubPermOpenSettings) {
                    Permissions.shared.openScreenRecordingSettings()
                }
            }
        }
    }

    private func hotkeysSection(_ manager: ScreenshotFeatureManager) -> some View {
        Section(strings.screenshotHotkeysSection) {
            ForEach(ScreenshotHotkeyEntry.allCases, id: \.rawValue) { entry in
                HStack {
                    Text(entry.label(in: strings))
                    Spacer()
                    HotkeyRecorderView(
                        displayText: manager.hotkey(for: entry).displayString,
                        onShortcutChanged: { shortcut in
                            manager.handleRecorderChange(entry, shortcut: shortcut)
                        },
                        l10n: state.l10n
                    )
                }
            }
        }
    }

    private var outputSection: some View {
        Section(strings.screenshotOutputSection) {
            VStack(alignment: .leading, spacing: 6) {
                Text(strings.screenshotSaveDirectory)
                Text(saveDirectoryPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button(strings.screenshotChooseDirectory) {
                    chooseDirectory(bindingPath: $saveDirectoryPath, prompt: strings.screenshotChooseDirectory)
                }
            }
            // 用 LabeledContent + 无标题 TextField，避免 Form 把 title 再渲染成一行「文件名前缀」。
            LabeledContent(strings.screenshotFileNamePrefixLabel) {
                TextField("", text: $fileNamePrefix)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .onSubmit {
                        fileNamePrefix = validatedPrefixOnSubmit(fileNamePrefix)
                    }
            }
            Text(strings.screenshotFileNamePrefixCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var recordingSection: some View {
        Section(strings.recordingSection) {
            VStack(alignment: .leading, spacing: 6) {
                Text(strings.recordingSaveDirectory)
                Text(recordingSaveDirectoryPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button(strings.recordingChooseDirectory) {
                    chooseDirectory(
                        bindingPath: $recordingSaveDirectoryPath,
                        prompt: strings.recordingChooseDirectory
                    )
                }
            }
            Picker(strings.recordingFormatPreference, selection: recordingSavePreference) {
                Text(strings.recordingFormatManual).tag(RecordingSavePreference.manual)
                Text(strings.recordingFormatMP4).tag(RecordingSavePreference.mp4)
                Text(strings.recordingFormatGIF).tag(RecordingSavePreference.gif)
            }
        }
    }

    private func chooseDirectory(bindingPath: Binding<String>, prompt: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: bindingPath.wrappedValue, isDirectory: true)
        panel.prompt = prompt
        if panel.runModal() == .OK, let url = panel.url {
            bindingPath.wrappedValue = url.path
        }
    }

    /// 提交时校验前缀：非法（空/含分隔符）回退默认。
    private func validatedPrefixOnSubmit(_ raw: String) -> String {
        let validated = ScreenshotOutputConfiguration.validatedPrefix(raw)
        if validated != raw.trimmingCharacters(in: .whitespacesAndNewlines) {
            manager?.recordMenuError(strings.screenshotFileNamePrefixInvalid)
        }
        return validated
    }
}
