import Foundation

/// 应用支持的语言。新增语言时需要：
/// 1. 在此处添加 case
/// 2. 在 L10n.s 的 switch 中添加对应分支
/// 3. 创建 Strings+<Language>.swift extension
enum AppLanguage: String, CaseIterable, Identifiable {
    case en = "en"
    case zhHans = "zh-Hans"

    var id: String { rawValue }

    /// 该语言在自身文字中的显示名称（用于语言选择器）
    var displayName: String {
        switch self {
        case .en: return "English"
        case .zhHans: return "简体中文"
        }
    }

    /// 从系统偏好检测默认语言
    static var systemDefault: AppLanguage {
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("zh") { return .zhHans }
        return .en
    }
}
