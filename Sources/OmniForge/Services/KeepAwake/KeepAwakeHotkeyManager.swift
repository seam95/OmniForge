import Combine
import Foundation

/// 保持唤醒全局快捷键：Carbon 生产监听 + 配置持久化。
/// 不使用 KeyboardShortcuts 作为 keep-awake 后端。
@MainActor
final class KeepAwakeHotkeyManager: ObservableObject {
    @Published private(set) var isRegistered = false
    @Published private(set) var registrationError: KeepAwakeError?
    @Published private(set) var hotkey: HotkeyDefinition

    private let registrar: CarbonHotkeyRegistering
    private let userDefaults: UserDefaults
    private let isFeatureAvailable: () -> Bool
    private let isHotkeyPreferenceEnabled: () -> Bool
    private let canToggle: () -> Result<Void, KeepAwakeError>
    private var onToggle: (() -> Void)?
    private var token: HotkeyRegistrationToken?
    private var isTearingDown = false
    private var isListening = false

    init(
        registrar: CarbonHotkeyRegistering,
        userDefaults: UserDefaults = .standard,
        isFeatureAvailable: @escaping () -> Bool = { true },
        isHotkeyPreferenceEnabled: @escaping () -> Bool = { true },
        canToggle: @escaping () -> Result<Void, KeepAwakeError> = { .success(()) }
    ) {
        self.registrar = registrar
        self.userDefaults = userDefaults
        self.isFeatureAvailable = isFeatureAvailable
        self.isHotkeyPreferenceEnabled = isHotkeyPreferenceEnabled
        self.canToggle = canToggle
        self.hotkey = Self.loadHotkey(from: userDefaults)
    }

    deinit {
        // 尽力注销；主路径应调用 stopListening / teardown。
    }

    func startListening(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        isListening = true
        isTearingDown = false
        reinstallRegistration()
    }

    func stopListening() {
        isListening = false
        onToggle = nil
        uninstallRegistration()
    }

    func teardown() {
        isTearingDown = true
        isListening = false
        onToggle = nil
        uninstallRegistration()
        if let registrar = registrar as? CarbonHotkeyRegistrar {
            registrar.teardown()
        }
    }

    /// 更新快捷键：先注销旧键再注册新键；只写 keepAwake.* 键。
    func updateHotkey(_ definition: HotkeyDefinition) {
        guard definition != hotkey else { return }
        hotkey = definition
        userDefaults.set(definition.keyCode, forKey: UserDefaultsKeys.keepAwakeHotkeyKeyCode)
        userDefaults.set(definition.modifiers.rawValue, forKey: UserDefaultsKeys.keepAwakeHotkeyModifiers)
        if isListening {
            reinstallRegistration()
        }
    }

    func syncRegistrationWithGates() {
        guard isListening, !isTearingDown else {
            uninstallRegistration()
            return
        }
        reinstallRegistration()
    }

    // MARK: - private

    private func reinstallRegistration() {
        uninstallRegistration()
        guard !isTearingDown else { return }
        guard isListening else { return }
        guard isFeatureAvailable() else {
            registrationError = .featureUnavailable
            isRegistered = false
            return
        }
        guard isHotkeyPreferenceEnabled() else {
            registrationError = nil
            isRegistered = false
            return
        }

        do {
            let newToken = try registrar.register(
                keyCode: UInt32(hotkey.keyCode),
                carbonModifiers: hotkey.modifiers.carbonFlags
            ) { [weak self] in
                // 生产事件桥已派发到主线程；测试 fake 同步调用。
                MainActor.assumeIsolated {
                    self?.handleKeyUp()
                }
            }
            token = newToken
            isRegistered = true
            registrationError = nil
        } catch let error as KeepAwakeError {
            token = nil
            isRegistered = false
            registrationError = error
        } catch {
            token = nil
            isRegistered = false
            registrationError = .hotkeyRegistrationFailed(status: -1)
        }
    }

    private func uninstallRegistration() {
        guard let token else {
            isRegistered = false
            return
        }
        do {
            try registrar.unregister(token)
            registrationError = nil
        } catch let error as KeepAwakeError {
            registrationError = error
        } catch {
            registrationError = .hotkeyUnregistrationFailed(status: -1)
        }
        self.token = nil
        isRegistered = false
    }

    private func handleKeyUp() {
        guard isListening, !isTearingDown else { return }
        guard isFeatureAvailable(), isHotkeyPreferenceEnabled() else { return }
        switch canToggle() {
        case .success:
            onToggle?()
        case .failure(let error):
            registrationError = error
        }
    }

    private static func loadHotkey(from userDefaults: UserDefaults) -> HotkeyDefinition {
        guard userDefaults.object(forKey: UserDefaultsKeys.keepAwakeHotkeyKeyCode) != nil,
              userDefaults.object(forKey: UserDefaultsKeys.keepAwakeHotkeyModifiers) != nil else {
            return .defaultKeepAwake
        }
        let keyCode = userDefaults.integer(forKey: UserDefaultsKeys.keepAwakeHotkeyKeyCode)
        let modifiers = HotkeyModifiers(
            rawValue: userDefaults.integer(forKey: UserDefaultsKeys.keepAwakeHotkeyModifiers)
        )
        return HotkeyDefinition(keyCode: keyCode, modifiers: modifiers)
    }
}
