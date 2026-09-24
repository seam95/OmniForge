import Foundation

/// FinderSync 扩展自包含的菜单文案。
///
/// 宿主的本地化是代码式协议（`Strings` + `Strings+English` / `Strings+ChineseSimplified`），
/// 但 appex 目标 `dependencies: []`、与宿主不共享代码，引用不到。若改用 `.lproj/*.strings`
/// 会形成第二套本地化源、与宿主重复维护，故在此按系统语言内联一份，改动集中在单文件内。
enum FinderSyncStrings {
    /// 按当前系统语言取文案。仅在首选语言明确为英语时取英文，其余（含中文与未设置）走中文，
    /// 与宿主 `AppLanguage.systemDefault` 的取舍保持一致。
    static func pick(_ zh: String, _ en: String) -> String {
        prefersEnglish ? en : zh
    }

    static var prefersEnglish: Bool {
        guard let first = Locale.preferredLanguages.first else { return false }
        return first.hasPrefix("en")
    }

    // MARK: - 菜单标题

    /// 新建文件
    static var newFile: String { pick("新建文件", "New File") }
    /// 在此处打开终端
    static var openTerminal: String { pick("在此处打开终端", "Open in Terminal") }
    /// 终端缺失时的兜底项
    static var terminalFallback: String { pick("终端 (Terminal)", "Terminal") }
    /// 在此处打开编辑器
    static var openEditor: String { pick("在此处打开编辑器", "Open in Editor") }
    /// 复制路径
    static var copyPath: String { pick("复制路径", "Copy Path") }
    /// 移动到...
    static var moveTo: String { pick("移动到...", "Move To…") }
    /// 复制到...
    static var copyTo: String { pick("复制到...", "Copy To…") }
    /// 常用目录直达
    static var quickJump: String { pick("常用目录直达", "Go To Folder") }
    /// 切换显示隐藏文件
    static var toggleHiddenFiles: String { pick("切换显示隐藏文件", "Toggle Hidden Files") }

    // MARK: - 带参数标题

    /// 新建文件子项，ext 为后缀名
    static func newFileItem(_ ext: String) -> String {
        pick("文件 (.\(ext))", "File (.\(ext))")
    }

    // MARK: - 复制路径格式

    /// 绝对路径 (POSIX)
    static var pathPOSIX: String { pick("绝对路径 (POSIX)", "Absolute Path (POSIX)") }
    /// Shell 转义路径
    static var pathShellEscaped: String { pick("Shell 转义路径", "Shell-Escaped Path") }
    /// 文件 URL
    static var pathURL: String { pick("文件 URL", "File URL") }
    /// 仅文件名
    static var pathFileName: String { pick("仅文件名", "File Name Only") }

    // MARK: - 常用目录显示名

    /// 桌面
    static var dirDesktop: String { pick("桌面", "Desktop") }
    /// 下载
    static var dirDownloads: String { pick("下载", "Downloads") }
    /// 文稿
    static var dirDocuments: String { pick("文稿", "Documents") }
}
