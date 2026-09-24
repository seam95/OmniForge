import Foundation

/// 访达右键增强配置管理器
public final class RightClickConfiguration {
    public static let shared = RightClickConfiguration()

    /// 宿主与沙盒化的 FinderSync 扩展共享配置所用的 app group。
    /// 必须带 Team ID 前缀——不带前缀的 group.* 标识会被 containermanagerd 用 TCC
    /// 拦起来，扩展侧 UserDefaults(suiteName:) 会 detaching from cfprefsd 读不到任何值。
    /// 宿主也必须声明 com.apple.security.application-groups，否则两端读写的是不同文件。
    public static let appGroupIdentifier = "P684VHKUAZ.group.app.omniforge"

    public struct Keys {
        public static let fileExtensions = "rightClick_fileExtensions"
        public static let isSubmenuCollapsed = "rightClick_isSubmenuCollapsed"
        public static let promotedActionKeys = "rightClick_promotedActionKeys"
        public static let favoriteDirectories = "rightClick_favoriteDirectories"
    }

    public static let defaultFileExtensions: [String] = ["txt", "md", "json", "sh", "swift", "py"]

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        if let customDefaults = defaults {
            self.defaults = customDefaults
        } else if let groupDefaults = UserDefaults(suiteName: Self.appGroupIdentifier) {
            self.defaults = groupDefaults
        } else {
            self.defaults = .standard
        }
    }

    // MARK: - 新建文件扩展名列表

    public var fileExtensions: [String] {
        get {
            let stored = defaults.stringArray(forKey: Keys.fileExtensions)
            return stored ?? Self.defaultFileExtensions
        }
        set {
            let normalized = Self.normalizeExtensions(newValue)
            defaults.set(normalized, forKey: Keys.fileExtensions)
        }
    }

    public func addFileExtension(_ ext: String) {
        let trimmed = ext.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !trimmed.isEmpty else { return }
        var current = fileExtensions
        if !current.contains(trimmed) {
            current.append(trimmed)
            fileExtensions = current
        }
    }

    public func removeFileExtension(_ ext: String) {
        let trimmed = ext.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        var current = fileExtensions
        current.removeAll { $0.lowercased() == trimmed }
        fileExtensions = current
    }

    public func resetFileExtensions() {
        fileExtensions = Self.defaultFileExtensions
    }

    // MARK: - 菜单层级配置

    public var isSubmenuCollapsed: Bool {
        get {
            if defaults.object(forKey: Keys.isSubmenuCollapsed) == nil {
                return true // 默认收敛到二级子菜单
            }
            return defaults.bool(forKey: Keys.isSubmenuCollapsed)
        }
        set {
            defaults.set(newValue, forKey: Keys.isSubmenuCollapsed)
        }
    }

    public var promotedActionKeys: Set<String> {
        get {
            let array = defaults.stringArray(forKey: Keys.promotedActionKeys) ?? []
            return Set(array)
        }
        set {
            defaults.set(Array(newValue), forKey: Keys.promotedActionKeys)
        }
    }

    public func isActionPromoted(_ actionKey: String) -> Bool {
        promotedActionKeys.contains(actionKey)
    }

    public func setActionPromoted(_ actionKey: String, isPromoted: Bool) {
        var current = promotedActionKeys
        if isPromoted {
            current.insert(actionKey)
        } else {
            current.remove(actionKey)
        }
        promotedActionKeys = current
    }

    // MARK: - 常用目录列表

    public var favoriteDirectories: [RightClickDirectoryItem] {
        get {
            guard let data = defaults.data(forKey: Keys.favoriteDirectories),
                  let items = try? JSONDecoder().decode([RightClickDirectoryItem].self, from: data) else {
                return Self.defaultFavoriteDirectories()
            }
            return items
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.favoriteDirectories)
            }
        }
    }

    public func addFavoriteDirectory(name: String, path: String) {
        var current = favoriteDirectories
        let item = RightClickDirectoryItem(name: name, path: path, isCustom: true)
        current.append(item)
        favoriteDirectories = current
    }

    public func removeFavoriteDirectory(id: UUID) {
        var current = favoriteDirectories
        current.removeAll { $0.id == id }
        favoriteDirectories = current
    }

    public static func defaultFavoriteDirectories() -> [RightClickDirectoryItem] {
        let fm = FileManager.default
        var items: [RightClickDirectoryItem] = []

        if let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first {
            items.append(RightClickDirectoryItem(name: "桌面", path: desktop.path, isCustom: false))
        }
        if let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            items.append(RightClickDirectoryItem(name: "下载", path: downloads.path, isCustom: false))
        }
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            items.append(RightClickDirectoryItem(name: "文稿", path: docs.path, isCustom: false))
        }
        return items
    }

    // MARK: - 辅助方法

    private static func normalizeExtensions(_ list: [String]) -> [String] {
        var result: [String] = []
        for item in list {
            let clean = item.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            if !clean.isEmpty && !result.contains(clean) {
                result.append(clean)
            }
        }
        return result
    }
}
