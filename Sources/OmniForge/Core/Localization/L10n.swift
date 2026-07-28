import Combine
import Foundation

/// 语言管理器：替代 LanguageManager，提供编译时类型安全的字符串访问。
/// SwiftUI View 通过 `@ObservedObject` 观察此对象，语言切换时界面自动重渲染。
final class L10n: ObservableObject {
    @Published private(set) var language: AppLanguage
    private let userDefaults: UserDefaults

    /// 当前语言的完整字符串目录
    var s: Strings {
        switch language {
        case .en: return .en
        case .zhHans: return .zhHans
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let raw = userDefaults.string(forKey: UserDefaultsKeys.preferredLanguage),
           let saved = AppLanguage(rawValue: raw) {
            language = saved
        } else {
            language = .systemDefault
        }
    }

    /// 设置语言。传入 nil 恢复为系统默认。
    func setLanguage(_ lang: AppLanguage?) {
        if let lang {
            language = lang
            userDefaults.set(lang.rawValue, forKey: UserDefaultsKeys.preferredLanguage)
        } else {
            userDefaults.removeObject(forKey: UserDefaultsKeys.preferredLanguage)
            language = .systemDefault
        }
    }
}
