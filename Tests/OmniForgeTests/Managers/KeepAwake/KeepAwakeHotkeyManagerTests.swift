import Carbon
import XCTest
@testable import OmniForge

@MainActor
final class KeepAwakeHotkeyManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var registrar: FakeCarbonRegistrar!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "keep-awake-hotkey-\(UUID().uuidString)")!
        registrar = FakeCarbonRegistrar()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "")
        super.tearDown()
    }

    private func makeManager(
        available: Bool = true,
        preferenceEnabled: Bool = true,
        canToggle: @escaping () -> Result<Void, KeepAwakeError> = { .success(()) }
    ) -> KeepAwakeHotkeyManager {
        KeepAwakeHotkeyManager(
            registrar: registrar,
            userDefaults: defaults,
            isFeatureAvailable: { available },
            isHotkeyPreferenceEnabled: { preferenceEnabled },
            canToggle: canToggle
        )
    }

    func test_defaultHotkey_isControlOptionCommandK() {
        let manager = makeManager()
        XCTAssertEqual(manager.hotkey, .defaultKeepAwake)
        XCTAssertEqual(manager.hotkey.keyCode, Int(kVK_ANSI_K))
    }

    func test_startListening_registersDefaultHotkey() {
        let manager = makeManager()
        manager.startListening(onToggle: {})
        XCTAssertTrue(manager.isRegistered)
        XCTAssertNil(manager.registrationError)
        XCTAssertEqual(registrar.registerCalls.count, 1)
        XCTAssertEqual(registrar.registerCalls[0].keyCode, UInt32(kVK_ANSI_K))
    }

    func test_keyUp_togglesOnce() {
        let manager = makeManager()
        var toggles = 0
        manager.startListening(onToggle: { toggles += 1 })
        registrar.fireKeyUp()
        registrar.fireKeyUp()
        XCTAssertEqual(toggles, 2)
    }

    func test_updateHotkey_unregistersThenRegisters() {
        let manager = makeManager()
        manager.startListening(onToggle: {})
        let custom = HotkeyDefinition(keyCode: Int(kVK_ANSI_A), modifiers: [.command])
        manager.updateHotkey(custom)
        XCTAssertEqual(registrar.unregisterCalls, 1)
        XCTAssertEqual(registrar.registerCalls.count, 2)
        XCTAssertEqual(manager.hotkey, custom)
        XCTAssertEqual(
            defaults.integer(forKey: UserDefaultsKeys.keepAwakeHotkeyKeyCode),
            custom.keyCode
        )
    }

    func test_featureUnavailable_doesNotRegister() {
        let manager = makeManager(available: false)
        manager.startListening(onToggle: {})
        XCTAssertFalse(manager.isRegistered)
        XCTAssertEqual(manager.registrationError, .featureUnavailable)
        XCTAssertTrue(registrar.registerCalls.isEmpty)
    }

    func test_preferenceDisabled_unregisters() {
        var preference = true
        let manager = KeepAwakeHotkeyManager(
            registrar: registrar,
            userDefaults: defaults,
            isFeatureAvailable: { true },
            isHotkeyPreferenceEnabled: { preference },
            canToggle: { .success(()) }
        )
        manager.startListening(onToggle: {})
        XCTAssertTrue(manager.isRegistered)
        preference = false
        manager.syncRegistrationWithGates()
        XCTAssertFalse(manager.isRegistered)
        XCTAssertEqual(registrar.unregisterCalls, 1)
    }

    func test_registrationConflict_publishesError() {
        registrar.registerError = .hotkeyRegistrationFailed(status: -9878)
        let manager = makeManager()
        manager.startListening(onToggle: {})
        XCTAssertFalse(manager.isRegistered)
        XCTAssertEqual(manager.registrationError, .hotkeyRegistrationFailed(status: -9878))
    }

    func test_canToggleReject_doesNotCallHandler() {
        let manager = makeManager(canToggle: { .failure(.operationInProgress) })
        var toggles = 0
        manager.startListening(onToggle: { toggles += 1 })
        registrar.fireKeyUp()
        XCTAssertEqual(toggles, 0)
        XCTAssertEqual(manager.registrationError, .operationInProgress)
    }

    func test_teardown_clearsRegistration() {
        let manager = makeManager()
        manager.startListening(onToggle: {})
        manager.teardown()
        XCTAssertFalse(manager.isRegistered)
        registrar.fireKeyUp()
        // 无 handler 可调用
    }

    func test_noKeyboardShortcutsNameForKeepAwake() {
        // 编译期：KeepAwake 不扩展 KeyboardShortcuts.Name。
        // 运行期：updateHotkey 只写 keepAwake 键。
        let manager = makeManager()
        let custom = HotkeyDefinition(keyCode: Int(kVK_ANSI_B), modifiers: [.option])
        manager.updateHotkey(custom)
        XCTAssertNil(defaults.object(forKey: UserDefaultsKeys.clipboardHotkeyKeyCode))
        XCTAssertEqual(
            defaults.integer(forKey: UserDefaultsKeys.keepAwakeHotkeyKeyCode),
            Int(kVK_ANSI_B)
        )
    }
}

// MARK: - Fake registrar

@MainActor
final class FakeCarbonRegistrar: CarbonHotkeyRegistering {
    struct RegisterCall {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    private(set) var registerCalls: [RegisterCall] = []
    private(set) var unregisterCalls = 0
    var registerError: KeepAwakeError?
    var unregisterError: KeepAwakeError?
    private var handler: (() -> Void)?
    private var tokenID: UInt32 = 0
    private var active = false

    func register(
        keyCode: UInt32,
        carbonModifiers: UInt32,
        handler: @escaping () -> Void
    ) throws -> HotkeyRegistrationToken {
        if let registerError { throw registerError }
        registerCalls.append(RegisterCall(keyCode: keyCode, modifiers: carbonModifiers))
        self.handler = handler
        tokenID += 1
        active = true
        return HotkeyRegistrationToken(id: tokenID)
    }

    func unregister(_ token: HotkeyRegistrationToken) throws {
        if let unregisterError { throw unregisterError }
        unregisterCalls += 1
        handler = nil
        active = false
    }

    func isActive(_ token: HotkeyRegistrationToken) -> Bool {
        active && token.id == tokenID
    }

    func teardown() {
        handler = nil
        active = false
    }

    func fireKeyUp() {
        handler?()
    }
}
