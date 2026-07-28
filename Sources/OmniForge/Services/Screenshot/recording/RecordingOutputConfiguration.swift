import Foundation

/// Resolved recording output preferences (directory + format preference).
struct RecordingOutputConfigurationSnapshot: Equatable {
    var saveDirectory: URL?
    var fileNamePrefix: String
    var savePreference: RecordingSavePreference
    var lastManualFormat: ScreenRecordingFormat
}

/// Reads/writes recording output settings from `UserDefaults`.
struct RecordingOutputConfiguration {
    static let defaultDirectoryPath = "~/Desktop"
    static let defaultPrefix = "Recording"
    static let defaultSavePreference = RecordingSavePreference.manual
    static let defaultManualFormat = ScreenRecordingFormat.mp4

    let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load() -> RecordingOutputConfigurationSnapshot {
        let dirString = userDefaults.string(forKey: UserDefaultsKeys.recordingSaveDirectoryPath) ?? ""
        let trimmedDir = dirString.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory: URL?
        if trimmedDir.isEmpty {
            directory = nil
        } else {
            let expanded = (trimmedDir as NSString).expandingTildeInPath
            directory = URL(fileURLWithPath: expanded, isDirectory: true)
        }

        let rawPreference = userDefaults.string(forKey: UserDefaultsKeys.recordingSavePreference) ?? ""
        let preference = RecordingSavePreference(rawValue: rawPreference) ?? Self.defaultSavePreference

        let rawManual = userDefaults.string(forKey: UserDefaultsKeys.recordingLastManualFormat) ?? ""
        let manual = ScreenRecordingFormat(rawValue: rawManual) ?? Self.defaultManualFormat

        return RecordingOutputConfigurationSnapshot(
            saveDirectory: directory,
            fileNamePrefix: Self.defaultPrefix,
            savePreference: preference,
            lastManualFormat: manual
        )
    }

    func setSavePreference(_ preference: RecordingSavePreference) {
        userDefaults.set(preference.rawValue, forKey: UserDefaultsKeys.recordingSavePreference)
    }

    func setLastManualFormat(_ format: ScreenRecordingFormat) {
        userDefaults.set(format.rawValue, forKey: UserDefaultsKeys.recordingLastManualFormat)
    }

    static func timestampedFileName(
        prefix: String,
        fileExtension: String,
        date: Date
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(prefix)-\(formatter.string(from: date)).\(fileExtension)"
    }
}
