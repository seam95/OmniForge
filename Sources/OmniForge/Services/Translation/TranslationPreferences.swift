import AppKit
import Combine
import Foundation

/// 翻译功能的可观察偏好。管理页、浮窗与设置页共享同一实例。
///
/// 写入即持久化；窗口位置由窗口控制器通过 `loadWindowFrame` / `saveWindowFrame` 复用同一偏好对象。
/// API Key 不在此处，走独立 Keychain。
@MainActor
final class TranslationPreferences: ObservableObject {
    /// 历史保留上限（默认最近 100 条）。
    static let defaultHistoryLimit = 100

    private let userDefaults: UserDefaults

    @Published var engine: TranslationEngineID {
        didSet {
            guard engine != oldValue else { return }
            userDefaults.set(engine.rawValue, forKey: UserDefaultsKeys.translationEngine)
        }
    }

    /// 源语言；nil 表示自动检测。
    @Published var sourceLanguage: String? {
        didSet {
            guard sourceLanguage != oldValue else { return }
            if let sourceLanguage, !sourceLanguage.isEmpty {
                userDefaults.set(sourceLanguage, forKey: UserDefaultsKeys.translationSourceLanguage)
            } else {
                userDefaults.removeObject(forKey: UserDefaultsKeys.translationSourceLanguage)
            }
        }
    }

    /// 目标语言策略；默认自动（中文与英语互译）。
    @Published var target: TranslationTarget {
        didSet {
            guard target != oldValue else { return }
            userDefaults.set(target.storageValue, forKey: UserDefaultsKeys.translationTargetLanguage)
        }
    }

    @Published var saveHistory: Bool {
        didSet {
            guard saveHistory != oldValue else { return }
            userDefaults.set(saveHistory, forKey: UserDefaultsKeys.translationSaveHistory)
        }
    }

    // MARK: - AI 配置（Key 除外）

    @Published var baseURL: String {
        didSet {
            guard baseURL != oldValue else { return }
            userDefaults.set(baseURL, forKey: UserDefaultsKeys.translationBaseURL)
        }
    }

    @Published var model: String {
        didSet {
            guard model != oldValue else { return }
            userDefaults.set(model, forKey: UserDefaultsKeys.translationModel)
        }
    }

    /// 当前快捷键；nil 表示用户显式禁用。
    @Published private(set) var hotkey: HotkeyDefinition?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        engine = TranslationEngineID(
            rawValue: userDefaults.string(forKey: UserDefaultsKeys.translationEngine) ?? ""
        ) ?? .system

        let storedSource = userDefaults.string(forKey: UserDefaultsKeys.translationSourceLanguage) ?? ""
        sourceLanguage = storedSource.isEmpty ? nil : storedSource

        target = TranslationTarget(
            storageValue: userDefaults.string(forKey: UserDefaultsKeys.translationTargetLanguage)
                ?? TranslationTarget.automaticStorageValue
        )

        // 注册默认值前（例如测试直接构造）也要表现为「保存历史开启」。
        saveHistory = userDefaults.object(forKey: UserDefaultsKeys.translationSaveHistory) == nil
            ? true
            : userDefaults.bool(forKey: UserDefaultsKeys.translationSaveHistory)

        baseURL = userDefaults.string(forKey: UserDefaultsKeys.translationBaseURL) ?? ""
        model = userDefaults.string(forKey: UserDefaultsKeys.translationModel) ?? ""

        hotkey = Self.loadHotkey(from: userDefaults)
    }

    // MARK: - 引擎可用性

    /// 系统翻译是否受当前系统版本支持（Translation 框架 macOS 15+）。
    /// nonisolated：调用方可能在非主 actor 上下文（默认参数、纯逻辑测试）判断版本门控。
    nonisolated static var isSystemTranslationSupported: Bool {
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }

    /// 本次运行实际使用的引擎。
    ///
    /// 存储偏好可能是 system，但 macOS 14 不支持系统翻译：此时仅本次运行解析为 AI，
    /// 不覆盖用户原始偏好（升级到 macOS 15 后恢复 system）。
    func effectiveEngine(systemAvailable: Bool = TranslationPreferences.isSystemTranslationSupported)
        -> TranslationEngineID {
        if engine == .system && !systemAvailable {
            return .ai
        }
        return engine
    }

    /// 存储偏好为 system 但当前运行不可用：界面需要提示"需配置 AI 接口"。
    func isSystemPreferenceDowngraded(
        systemAvailable: Bool = TranslationPreferences.isSystemTranslationSupported
    ) -> Bool {
        engine == .system && !systemAvailable
    }

    /// AI 配置是否已具备提交条件（Key 可选，不在此判断）。
    var isAIConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 由当前偏好与已读取的 Key 构造 AI 配置。
    func aiConfiguration(apiKey: String?) -> AITranslationConfiguration {
        AITranslationConfiguration(
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey
        )
    }

    // MARK: - 快捷键

    /// 写入快捷键；传 nil 表示禁用（保留已录入键位，便于恢复）。
    func setHotkey(_ definition: HotkeyDefinition?) {
        guard let definition else {
            userDefaults.set(false, forKey: UserDefaultsKeys.translationHotkeyEnabled)
            hotkey = nil
            return
        }
        userDefaults.set(true, forKey: UserDefaultsKeys.translationHotkeyEnabled)
        userDefaults.set(definition.keyCode, forKey: UserDefaultsKeys.translationHotkeyKeyCode)
        userDefaults.set(
            definition.modifiers.rawValue,
            forKey: UserDefaultsKeys.translationHotkeyModifiers
        )
        hotkey = definition
    }

    /// 重新读取持久化快捷键（录键组件直接写 UserDefaults 后同步内存态）。
    func reloadHotkey() {
        hotkey = Self.loadHotkey(from: userDefaults)
    }

    private static func loadHotkey(from userDefaults: UserDefaults) -> HotkeyDefinition? {
        // 未注册默认值时按默认启用，避免首启无快捷键。
        if userDefaults.object(forKey: UserDefaultsKeys.translationHotkeyEnabled) != nil,
           !userDefaults.bool(forKey: UserDefaultsKeys.translationHotkeyEnabled) {
            return nil
        }
        guard userDefaults.object(forKey: UserDefaultsKeys.translationHotkeyKeyCode) != nil,
              userDefaults.object(forKey: UserDefaultsKeys.translationHotkeyModifiers) != nil else {
            return .defaultTranslation
        }
        return HotkeyDefinition(
            keyCode: userDefaults.integer(forKey: UserDefaultsKeys.translationHotkeyKeyCode),
            modifiers: HotkeyModifiers(
                rawValue: userDefaults.integer(forKey: UserDefaultsKeys.translationHotkeyModifiers)
            )
        )
    }

    // MARK: - 窗口 frame

    /// 读取持久化窗口 frame；未保存过返回 nil。
    func loadWindowFrame() -> NSRect? {
        guard let stored = userDefaults.object(
            forKey: UserDefaultsKeys.translationWindowFrame
        ) as? [String: CGFloat] else {
            return nil
        }
        guard let x = stored["x"], let y = stored["y"],
              let width = stored["width"], let height = stored["height"] else {
            return nil
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    func saveWindowFrame(_ frame: NSRect) {
        let stored: [String: CGFloat] = [
            "x": frame.origin.x,
            "y": frame.origin.y,
            "width": frame.size.width,
            "height": frame.size.height,
        ]
        userDefaults.set(stored, forKey: UserDefaultsKeys.translationWindowFrame)
    }
}
