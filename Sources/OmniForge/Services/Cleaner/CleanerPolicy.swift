import Foundation

/// 清理器的所有判断汇集一处：审查列表中哪些默认勾选、哪些根本不出现。
/// 准则是 —— 只有证据充分且重建数据成本低时才预选；任何基于猜测的条目默认不勾选，等用户过目。
enum CleanerPolicy {
    /// 残留是针对已安装 app 预言机的经验性猜测，默认不勾选，界面会解释它们是什么。
    static let precheckLeftovers = false

    /// 失效启动项需要两个独立信号（所有可执行文件已失活 且 label 无活跃 owner），因此默认勾选；
    /// 它们是「登录项与扩展」里的幽灵。
    static let precheckLoginItems = true

    /// 日志是 app 会自由重写的诊断文本。
    static let precheckLogs = true

    /// 构建产物和模拟器缓存在下次构建时重新生成。
    static let precheckDeveloper = true

    /// 相对于 home 目录。仅在存在时才提供。DeviceSupport 目录是 Xcode 在下次连接设备时重建的
    /// 调试符号缓存；它们悄悄增长到几十 GB，是 macOS「其他」存储的经典切片。
    static let developerJunkPaths: [String] = [
        "/Library/Developer/Xcode/DerivedData",
        "/Library/Developer/Xcode/DocumentationCache",
        "/Library/Developer/CoreSimulator/Caches",
        "/Library/Developer/Xcode/iOS DeviceSupport",
        "/Library/Developer/Xcode/watchOS DeviceSupport",
        "/Library/Developer/Xcode/tvOS DeviceSupport",
    ]

    /// 设备备份是用户的安全网：巨大、古老、且是「其他」存储的另一个经典租户，
    /// 但绝不该由机器决定删除。每个发现默认不勾选，等用户过目。
    static let precheckDeviceBackups = false

    /// 完全不出现在列表中的缓存目录：本 app 自身数据，以及已知删除后会出问题的条目
    /// （音频丢失、设置面板空白、服务登出、插件授权），每条都是前人踩坑换来的教训。
    /// 同时屏蔽新名 `app.omniforge` 与历史名 `app.inputlock`，避免清理老版本残留数据。
    private static let hiddenCachePrefixes = [
        "app.omniforge",
        "app.inputlock",
        "CloudKit", "com.apple.bird",
        "com.apple.coreaudio", "com.apple.audio.", "coreaudiod",
        "com.apple.systempreferences", "com.apple.controlcenter",
        "com.apple.finder", "com.apple.dock",
        "com.apple.FontRegistry", "com.apple.ATS",
        "com.apple.akd", "com.apple.AuthKit",
        "com.paceap.", "com.native-instruments", "com.fabfilter",
    ]

    /// 用户付费带宽或配置换来的第三方缓存（离线媒体、模型与浏览器下载）：展示，但永不预选。
    private static let sensitiveCachePrefixes = [
        "com.spotify.client",
        "ms-playwright",
    ]

    static func isExcludedCacheEntry(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return hiddenCachePrefixes.contains { lowered.hasPrefix($0.lowercased()) }
    }

    /// 已知的纯下载或构建垃圾的纯名称缓存目录；此列表之外的纯名称条目默认不勾选，
    /// 因为裸名称无法归因（有些是系统自身的，如地图瓦片缓存）。
    private static let safePlainNameCaches: Set<String> = [
        "homebrew", "pip", "node-gyp", "yarn", "npm", "google",
        "electron", "cypress", "typescript", "puppeteer",
    ]

    /// Apple 自身缓存可安全删除，但系统会积极重建（首次启动变慢、重新索引），
    /// 因此列给愿意的人，但对谁都不预选。第三方缓存默认勾选，除非持有值得保留的内容；
    /// 纯名称目录仅在是已知下载或构建缓存时才勾选。
    static func precheckCacheEntry(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if sensitiveCachePrefixes.contains(where: { lowered.hasPrefix($0.lowercased()) }) { return false }
        if CleanerSupport.looksLikeBundleID(name) {
            return !lowered.hasPrefix("com.apple.")
        }
        return safePlainNameCaches.contains(lowered)
    }
}
