import KeyboardShortcuts
import XCTest
@testable import OmniForge

private final class FakeTranslationKeyboardShortcutsClient: TranslationKeyboardShortcutsClient {
    private(set) var shortcuts: [KeyboardShortcuts.Shortcut?] = []
    private(set) var handler: (() -> Void)?

    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name) {
        shortcuts.append(shortcut)
    }

    func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {
        handler = action
    }

    /// 模拟用户按下已注册快捷键。
    func trigger() {
        handler?()
    }
}

@MainActor
final class TranslationHotkeyManagerTests: XCTestCase {
    private var suiteName = ""
    private var userDefaults: UserDefaults!
    private var preferences: TranslationPreferences!
    private var client: FakeTranslationKeyboardShortcutsClient!
    private var triggerCount = 0
    private var isFeatureAvailable = true
    private var conflictDefinition: HotkeyDefinition?

    override func setUp() {
        super.setUp()
        suiteName = "TranslationHotkeyManagerTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
        Defaults.register(in: userDefaults)
        preferences = TranslationPreferences(userDefaults: userDefaults)
        client = FakeTranslationKeyboardShortcutsClient()
        triggerCount = 0
        isFeatureAvailable = true
        conflictDefinition = nil
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeManager() -> TranslationHotkeyManager {
        TranslationHotkeyManager(
            preferences: preferences,
            keyboardShortcuts: client,
            isFeatureAvailable: { [weak self] in self?.isFeatureAvailable ?? false },
            conflictProvider: { [weak self] definition in
                guard let self, let conflictDefinition = self.conflictDefinition else { return nil }
                return definition == conflictDefinition ? conflictDefinition : nil
            },
            onTrigger: { [weak self] in self?.triggerCount += 1 }
        )
    }

    // MARK: - 注册

    func test_startRegistersDefaultHotkey() {
        let manager = makeManager()
        manager.start()

        XCTAssertTrue(manager.isListening)
        XCTAssertEqual(client.shortcuts.count, 1)
        XCTAssertEqual(client.shortcuts.last ?? nil, HotkeyDefinition.defaultTranslation.keyboardShortcut)
        XCTAssertEqual(preferences.hotkey, .defaultTranslation)
    }

    func test_disabledHotkeyDoesNotReregisterOnRestart() {
        let manager = makeManager()
        try? manager.setHotkey(nil)
        manager.stop()

        // 「重启」：新实例读取同一偏好。
        let restarted = makeManager()
        restarted.start()

        XCTAssertTrue(restarted.isListening)
        XCTAssertEqual(client.shortcuts.last ?? nil, nil, "禁用快捷键后重启仍不注册")
        XCTAssertNil(preferences.hotkey)
    }

    func test_featureUnavailableStopsRegistration() {
        isFeatureAvailable = false
        let manager = makeManager()
        manager.start()

        XCTAssertFalse(manager.isListening)
        XCTAssertEqual(client.shortcuts.last ?? nil, nil)
    }

    // MARK: - 触发

    func test_registeredHandlerForwardsTrigger() {
        let manager = makeManager()
        manager.start()

        client.trigger()

        XCTAssertEqual(triggerCount, 1)
    }

    func test_teardownRemovesListenerWithoutDeletingHistory() {
        let manager = makeManager()
        manager.start()
        manager.stop()

        XCTAssertFalse(manager.isListening)
        XCTAssertEqual(client.shortcuts.last ?? nil, nil, "teardown 必须注销全局快捷键")
        // 偏好仍保留，重新启用后可恢复。
        XCTAssertEqual(preferences.hotkey, .defaultTranslation)
    }

    // MARK: - 冲突

    func test_conflictingHotkeyKeepsPreviousBinding() {
        let conflicting = HotkeyDefinition(
            keyCode: HotkeyDefinition.defaultClipboard.keyCode,
            modifiers: HotkeyDefinition.defaultClipboard.modifiers
        )
        conflictDefinition = conflicting
        let manager = makeManager()
        manager.start()
        let shortcutsBefore = client.shortcuts.count

        XCTAssertThrowsError(try manager.setHotkey(conflicting)) { error in
            XCTAssertEqual(error as? TranslationHotkeyError, .conflict(conflicting))
        }

        XCTAssertEqual(preferences.hotkey, .defaultTranslation, "冲突不得写入偏好")
        XCTAssertEqual(client.shortcuts.count, shortcutsBefore, "冲突不得替换当前绑定")
    }

    func test_disableThenReenableRestoresBinding() throws {
        let manager = makeManager()
        manager.start()

        try manager.setHotkey(nil)
        XCTAssertNil(preferences.hotkey, "禁用后偏好为 nil")
        XCTAssertEqual(client.shortcuts.last ?? nil, nil, "禁用后注销全局快捷键")

        // 录键可再次启用：功能保留，只恢复全局快捷键。
        let custom = HotkeyDefinition(
            keyCode: HotkeyDefinition.defaultTranslation.keyCode,
            modifiers: [.option, .command]
        )
        try manager.setHotkey(custom)
        XCTAssertEqual(preferences.hotkey, custom)
        XCTAssertEqual(client.shortcuts.last ?? nil, custom.keyboardShortcut)
    }

    func test_validHotkeyIsPersistedAndApplied() throws {
        let custom = HotkeyDefinition(
            keyCode: HotkeyDefinition.defaultTranslation.keyCode,
            modifiers: [.option, .shift, .command]
        )
        let manager = makeManager()
        manager.start()

        try manager.setHotkey(custom)

        XCTAssertEqual(preferences.hotkey, custom)
        XCTAssertEqual(client.shortcuts.last ?? nil, custom.keyboardShortcut)
    }
}
