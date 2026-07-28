import Foundation

/// 截图输出已解析配置快照（保存目录 + 文件名前缀）。
struct ScreenshotOutputConfigurationSnapshot: Equatable {
    /// 目标目录；`nil` 时由 `ScreenshotSaver` 回退默认桌面。
    var saveDirectory: URL?
    /// 已校验的文件名前缀。
    var fileNamePrefix: String
}

/// 从注入的 `UserDefaults` 读取截图输出配置。
///
/// 默认值与 `Defaults.screenshotDefaults` 对齐：`~/Desktop` + `Screenshot`。
struct ScreenshotOutputConfiguration {
    /// 与 `Defaults` 注册值一致的单一事实源。
    static let defaultPrefix = "Screenshot"
    static let defaultDirectoryPath = "~/Desktop"

    let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// 读取快照；非法前缀回退默认，空目录路径视为未配置。
    func load() -> ScreenshotOutputConfigurationSnapshot {
        let dirString = userDefaults.string(forKey: UserDefaultsKeys.screenshotSaveDirectoryPath) ?? ""
        let trimmedDir = dirString.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory: URL?
        if trimmedDir.isEmpty {
            directory = nil
        } else {
            let expanded = (trimmedDir as NSString).expandingTildeInPath
            directory = URL(fileURLWithPath: expanded, isDirectory: true)
        }

        let rawPrefix = userDefaults.string(forKey: UserDefaultsKeys.screenshotFileNamePrefix) ?? ""
        return ScreenshotOutputConfigurationSnapshot(
            saveDirectory: directory,
            fileNamePrefix: Self.validatedPrefix(rawPrefix)
        )
    }

    /// 前缀校验：空或含路径分隔符则回退默认。
    /// 与设置页 `validatedPrefixOnSubmit` 同语义，供 UI 与保存链路共用。
    static func validatedPrefix(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":") else {
            return defaultPrefix
        }
        return trimmed
    }
}
