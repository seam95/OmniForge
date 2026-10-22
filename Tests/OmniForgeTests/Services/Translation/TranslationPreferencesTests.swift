import XCTest
@testable import OmniForge

@MainActor
final class TranslationPreferencesTests: XCTestCase {
    private var suiteName = ""
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TranslationPreferencesTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
        Defaults.register(in: userDefaults)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - 默认值

    func test_defaultsAreSystemEngineAutomaticTargetAndEnabledHotkey() {
        let preferences = TranslationPreferences(userDefaults: userDefaults)

        XCTAssertEqual(preferences.engine, .system)
        XCTAssertNil(preferences.sourceLanguage)
        XCTAssertEqual(preferences.target, .automatic)
        XCTAssertTrue(preferences.saveHistory)
        XCTAssertEqual(preferences.hotkey, .defaultTranslation)
        XCTAssertEqual(preferences.hotkey?.displayString, "⌥⌘T")
    }

    func test_defaultHotkeyIsOptionCommandT() {
        XCTAssertEqual(HotkeyDefinition.defaultTranslation.modifiers.symbolString, "⌥⌘")
        XCTAssertEqual(HotkeyDefinition.defaultTranslation.displayString, "⌥⌘T")
    }

    // MARK: - 系统版本门控

    func test_systemPreferenceDowngradesToAIOnOlderSystemWithoutOverwritingStoredValue() {
        let preferences = TranslationPreferences(userDefaults: userDefaults)
        preferences.engine = .system

        XCTAssertEqual(
            preferences.effectiveEngine(systemAvailable: false),
            .ai,
            "macOS 14 上系统偏好本次运行解析为 AI"
        )
        XCTAssertEqual(preferences.effectiveEngine(systemAvailable: true), .system)
        XCTAssertEqual(preferences.engine, .system, "降级不得覆盖存储偏好")
        XCTAssertTrue(preferences.isSystemPreferenceDowngraded(systemAvailable: false))
    }

    // MARK: - 持久化

    func test_disabledHotkeyPersistsAcrossRestart() {
        let preferences = TranslationPreferences(userDefaults: userDefaults)
        preferences.setHotkey(nil)

        let restarted = TranslationPreferences(userDefaults: userDefaults)
        XCTAssertNil(restarted.hotkey, "禁用快捷键后重启仍为 nil")
    }

    func test_customHotkeyPersistsAcrossRestart() {
        let custom = HotkeyDefinition(keyCode: 17, modifiers: [.control, .option, .command])
        let preferences = TranslationPreferences(userDefaults: userDefaults)
        preferences.setHotkey(custom)

        let restarted = TranslationPreferences(userDefaults: userDefaults)
        XCTAssertEqual(restarted.hotkey, custom)
    }

    func test_languageAndTargetPersist() {
        let preferences = TranslationPreferences(userDefaults: userDefaults)
        preferences.sourceLanguage = "ja"
        preferences.target = .language("zh-Hant")
        preferences.saveHistory = false

        let restarted = TranslationPreferences(userDefaults: userDefaults)
        XCTAssertEqual(restarted.sourceLanguage, "ja")
        XCTAssertEqual(restarted.target, .language("zh-Hant"))
        XCTAssertFalse(restarted.saveHistory)
    }

    func test_windowFrameRoundTrip() {
        let preferences = TranslationPreferences(userDefaults: userDefaults)
        XCTAssertNil(preferences.loadWindowFrame())

        let frame = NSRect(x: 120, y: 240, width: 600, height: 520)
        preferences.saveWindowFrame(frame)

        XCTAssertEqual(preferences.loadWindowFrame(), frame)
    }

    // MARK: - AI 配置

    func test_aiConfigurationRequiresBaseURLAndModel() {
        let preferences = TranslationPreferences(userDefaults: userDefaults)
        XCTAssertFalse(preferences.isAIConfigured)

        preferences.baseURL = "https://api.example.com/v1"
        XCTAssertFalse(preferences.isAIConfigured)

        preferences.model = "example-model"
        XCTAssertTrue(preferences.isAIConfigured)
        XCTAssertEqual(
            preferences.aiConfiguration(apiKey: "key"),
            AITranslationConfiguration(
                baseURL: "https://api.example.com/v1",
                model: "example-model",
                apiKey: "key"
            )
        )
    }

    func test_targetStorageRoundTrip() {
        XCTAssertEqual(TranslationTarget(storageValue: "automatic"), .automatic)
        XCTAssertEqual(TranslationTarget(storageValue: ""), .automatic)
        XCTAssertEqual(TranslationTarget(storageValue: "zh-Hans"), .language("zh-Hans"))
        XCTAssertEqual(TranslationTarget.automatic.storageValue, "automatic")
        XCTAssertEqual(TranslationTarget.language("en").storageValue, "en")
    }
}
