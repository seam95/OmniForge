// Sources/OmniForge/Services/Screenshot/clothesline/ScreenshotInboxSettings.swift
import Foundation

/// `com.apple.screencapture` 偏好域读写边界（测试注入替身）。
/// 走 cfprefsd 直写直读，系统截图服务立即生效。
protocol ScreenshotPreferencesStore: AnyObject {
    func copyValue(forKey key: String, domain: String) -> Any?
    func setValue(_ value: Any?, forKey key: String, domain: String)
    func synchronize(domain: String)
}

final class CFPreferencesScreenshotStore: ScreenshotPreferencesStore {
    func copyValue(forKey key: String, domain: String) -> Any? {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }

    func setValue(_ value: Any?, forKey key: String, domain: String) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
    }

    func synchronize(domain: String) {
        CFPreferencesAppSynchronize(domain as CFString)
    }
}

/// Inbox 接管：改写系统截图落点（跳过浮动缩略图、不再落桌面），指向我方保存目录。
/// 旧值先保存；关闭、退出、停用、终止信号四路还原。
final class ScreenshotInboxSettings {
    private static let domain = "com.apple.screencapture"
    /// macOS 26 及更早读 location；macOS 27 读 location-screenshot 并忽略旧键，两键都写。
    private static let locationKey = "location"
    private static let screenshotLocationKey = "location-screenshot"
    private static let thumbnailKey = "show-thumbnail"

    private let store: ScreenshotPreferencesStore
    private let userDefaults: UserDefaults

    init(store: ScreenshotPreferencesStore = CFPreferencesScreenshotStore(),
         userDefaults: UserDefaults = .standard) {
        self.store = store
        self.userDefaults = userDefaults
    }

    var isEnabled: Bool {
        get { userDefaults.bool(forKey: UserDefaultsKeys.screenshotClotheslineInboxEnabled) }
        set { userDefaults.set(newValue, forKey: UserDefaultsKeys.screenshotClotheslineInboxEnabled) }
    }

    var wasOffered: Bool {
        get { userDefaults.bool(forKey: UserDefaultsKeys.screenshotClotheslineInboxOffered) }
        set { userDefaults.set(newValue, forKey: UserDefaultsKeys.screenshotClotheslineInboxOffered) }
    }

    /// 系统是否正把截图发往目标目录（两键都指向它才算）。
    func isApplied(targetDirectory: URL) -> Bool {
        let path = targetDirectory.standardizedFileURL.path
        for key in [Self.locationKey, Self.screenshotLocationKey] {
            guard let raw = store.copyValue(forKey: key, domain: Self.domain) as? String,
                  URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path == path
            else { return false }
        }
        return true
    }

    /// 接管：建目录 → 存旧值（仅首次且当前并非自身生效）→ 写两键 → 关缩略图。
    func apply(targetDirectory: URL) {
        try? FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        isEnabled = true
        // 完全生效时直接返回：既不重存旧值（防崩溃残留被当成旧值），也不必重写系统偏好。
        guard !isApplied(targetDirectory: targetDirectory) else { return }
        // 旧值只在首次接管时保存：后续 apply（目录变化）已有存档，
        // 此时系统偏好里是自身写入值，再存会把接管值误存为旧值，导致 restore 无法回到用户原状态。
        if userDefaults.dictionary(forKey: UserDefaultsKeys.screenshotClotheslineInboxSavedSettings) == nil {
            let previous: [String: Any] = [
                "location": (store.copyValue(forKey: Self.locationKey, domain: Self.domain) as? String) ?? NSNull(),
                "locationScreenshot": (store.copyValue(forKey: Self.screenshotLocationKey, domain: Self.domain) as? String) ?? NSNull(),
                "thumbnail": (store.copyValue(forKey: Self.thumbnailKey, domain: Self.domain) as? Bool) ?? NSNull(),
            ]
            userDefaults.set(previous.compactMapValues { $0 is NSNull ? nil : $0 },
                             forKey: UserDefaultsKeys.screenshotClotheslineInboxSavedSettings)
        }
        store.setValue(targetDirectory.path, forKey: Self.locationKey, domain: Self.domain)
        store.setValue(targetDirectory.path, forKey: Self.screenshotLocationKey, domain: Self.domain)
        store.setValue(false, forKey: Self.thumbnailKey, domain: Self.domain)
    }

    /// 还原旧值；键原本不存在则删除（恢复系统默认）。仅当当前确实生效才动作。
    func restore() {
        isEnabled = false
        guard let target = savedTargetDirectory(), isApplied(targetDirectory: target) else { return }
        let saved = userDefaults.dictionary(forKey: UserDefaultsKeys.screenshotClotheslineInboxSavedSettings) ?? [:]
        store.setValue(saved["location"], forKey: Self.locationKey, domain: Self.domain)
        store.setValue(saved["locationScreenshot"], forKey: Self.screenshotLocationKey, domain: Self.domain)
        store.setValue(saved["thumbnail"], forKey: Self.thumbnailKey, domain: Self.domain)
        userDefaults.removeObject(forKey: UserDefaultsKeys.screenshotClotheslineInboxSavedSettings)
    }

    /// 从已存旧值推出当时的接管目录（location 即当时目标）。
    private func savedTargetDirectory() -> URL? {
        (store.copyValue(forKey: Self.locationKey, domain: Self.domain) as? String)
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }
}
