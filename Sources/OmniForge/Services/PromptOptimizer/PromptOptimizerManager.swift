import AppKit
import Combine
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let promptOptimizer = Self("promptOptimizer")
}

// MARK: - KeyboardShortcuts 边界

/// KeyboardShortcuts write surface（对齐截图模式的协议抽象，便于测试注入）。
protocol PromptOptimizerKeyboardShortcutsClient: AnyObject {
    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name)
    func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping () -> Void)
}

/// Production KeyboardShortcuts adapter.
final class LivePromptOptimizerKeyboardShortcutsClient: PromptOptimizerKeyboardShortcutsClient {
    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name) {
        KeyboardShortcuts.setShortcut(shortcut, for: name)
    }

    func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {
        KeyboardShortcuts.onKeyUp(for: name, action: action)
    }
}

// MARK: - Manager

/// 提示词优化编排：快捷键触发 → AX 取词 → LLM 优化 → 写剪贴板（可选注入 ⌘V 替换）→ HUD 状态流转。
/// 状态机 idle/running：running 期间重复触发直接忽略（决策 D7，不排队不复用）。
@MainActor
final class PromptOptimizerManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
    }

    @Published private(set) var phase: Phase = .idle

    private let userDefaults: UserDefaults
    private let isFeatureAvailable: () -> Bool
    private let isAccessibilityGranted: () -> Bool
    private let stringsProvider: () -> Strings
    private let reader: SelectedTextReading
    /// 每次触发时按当前配置构造服务；API Key 未配置 → nil（决策 D1/D7 的「未配置」短路）。
    private let serviceFactory: () -> PromptOptimizing?
    private let writer: PasteboardWriting
    private let keyPoster: KeyEventPosting
    private let hud: PromptOptimizerHUDPresenting
    private let keyboardShortcuts: PromptOptimizerKeyboardShortcutsClient

    @Published private(set) var isListening = false
    private var registeredHandler = false

    init(
        userDefaults: UserDefaults = .standard,
        isFeatureAvailable: @escaping () -> Bool = { true },
        isAccessibilityGranted: @escaping () -> Bool = { AXIsProcessTrusted() },
        stringsProvider: @escaping () -> Strings = { .en },
        reader: SelectedTextReading = AXSelectedTextReader(),
        serviceFactory: @escaping () -> PromptOptimizing?,
        writer: PasteboardWriting = SystemPasteboardWriter(),
        keyPoster: KeyEventPosting = SystemKeyEventPoster(),
        hud: PromptOptimizerHUDPresenting,
        keyboardShortcuts: PromptOptimizerKeyboardShortcutsClient = LivePromptOptimizerKeyboardShortcutsClient()
    ) {
        self.userDefaults = userDefaults
        self.isFeatureAvailable = isFeatureAvailable
        self.isAccessibilityGranted = isAccessibilityGranted
        self.stringsProvider = stringsProvider
        self.reader = reader
        self.serviceFactory = serviceFactory
        self.writer = writer
        self.keyPoster = keyPoster
        self.hud = hud
        self.keyboardShortcuts = keyboardShortcuts
    }

    // MARK: - 生命周期

    /// availability 即启用：可用 → 注册快捷键，不可用 → 注销（FeatureRuntime binding 调用）。
    func syncWithPreferences() {
        if isFeatureAvailable() {
            startListening()
        } else {
            stopListening()
        }
    }

    func startListening() {
        isListening = true
        keyboardShortcuts.setShortcut(hotkey.keyboardShortcut, for: .promptOptimizer)
        registerHandlerIfNeeded()
    }

    func stopListening() {
        isListening = false
        keyboardShortcuts.setShortcut(nil, for: .promptOptimizer)
    }

    func teardown() {
        stopListening()
        phase = .idle
    }

    // MARK: - 快捷键（UserDefaults 为真源，KeyboardShortcuts 为运行时镜像）

    var hotkey: HotkeyDefinition {
        Self.loadHotkey(from: userDefaults)
    }

    func handleRecorderChange(_ shortcut: KeyboardShortcuts.Shortcut?) {
        guard let definition = HotkeyDefinition(shortcut: shortcut) else {
            // 清空录键回退当前生效快捷键，避免「录一半」留下空窗。
            if isListening {
                keyboardShortcuts.setShortcut(hotkey.keyboardShortcut, for: .promptOptimizer)
            }
            return
        }
        userDefaults.set(definition.keyCode, forKey: UserDefaultsKeys.promptOptimizerHotkeyKeyCode)
        userDefaults.set(definition.modifiers.rawValue, forKey: UserDefaultsKeys.promptOptimizerHotkeyModifiers)
        if isListening {
            keyboardShortcuts.setShortcut(definition.keyboardShortcut, for: .promptOptimizer)
        }
    }

    // MARK: - 触发

    func handleHotkey() {
        guard phase == .idle else { return }
        phase = .running
        Task { [weak self] in
            await self?.runOnce()
            self?.phase = .idle
        }
    }

    private func runOnce() async {
        // 同步预检：失败直接显示错误，不闪「优化中」。
        guard let service = serviceFactory() else {
            hud.showOutcome(stringsProvider().promptOptimizerErrorNotConfigured, isFailure: true)
            return
        }
        guard isAccessibilityGranted() else {
            hud.showOutcome(stringsProvider().promptOptimizerErrorNoAccessibility, isFailure: true)
            return
        }
        switch reader.readSelectedText() {
        case .success(let selectedText):
            hud.showRunning(stringsProvider().promptOptimizerRunning)
            do {
                let enhanced = try await service.optimize(selectedText: selectedText)
                writer.clearContents()
                writer.setString(enhanced, forType: .string)
                if isAutoReplaceEnabled {
                    // 粘贴作用于返回时刻焦点应用的当前选区/光标（决策 D6 的预期行为语义）。
                    keyPoster.postCommandV()
                }
                hud.showOutcome(stringsProvider().promptOptimizerSuccess, isFailure: false)
            } catch let error as PromptOptimizerErrorKind {
                hud.showOutcome(Self.failureText(for: error, strings: stringsProvider()), isFailure: true)
            } catch {
                hud.showOutcome(stringsProvider().promptOptimizerErrorGeneric, isFailure: true)
            }
        case .failure(.accessibilityInactive):
            // trusted 通过但 AX 调用失败（授权未生效的假阳性）——与预检未授权同文案。
            hud.showOutcome(stringsProvider().promptOptimizerErrorNoAccessibility, isFailure: true)
        case .failure(.noSelection):
            hud.showOutcome(stringsProvider().promptOptimizerErrorNoSelection, isFailure: true)
        }
    }

    // MARK: - 私有

    private var isAutoReplaceEnabled: Bool {
        userDefaults.bool(forKey: UserDefaultsKeys.promptOptimizerAutoReplace)
    }

    private static func failureText(for kind: PromptOptimizerErrorKind, strings: Strings) -> String {
        switch kind {
        case .notConfigured: return strings.promptOptimizerErrorNotConfigured
        case .noSelection: return strings.promptOptimizerErrorNoSelection
        case .noAccessibility: return strings.promptOptimizerErrorNoAccessibility
        case .network: return strings.promptOptimizerErrorNetwork
        case .timeout: return strings.promptOptimizerErrorTimeout
        case .unauthorized: return strings.promptOptimizerErrorUnauthorized
        case .generic: return strings.promptOptimizerErrorGeneric
        }
    }

    private func registerHandlerIfNeeded() {
        guard !registeredHandler else { return }
        keyboardShortcuts.onKeyUp(for: .promptOptimizer) { [weak self] in
            if Thread.isMainThread {
                self?.handleHotkey()
            } else {
                Task { @MainActor in
                    self?.handleHotkey()
                }
            }
        }
        registeredHandler = true
    }

    private static func loadHotkey(from userDefaults: UserDefaults) -> HotkeyDefinition {
        guard userDefaults.object(forKey: UserDefaultsKeys.promptOptimizerHotkeyKeyCode) != nil,
              userDefaults.object(forKey: UserDefaultsKeys.promptOptimizerHotkeyModifiers) != nil else {
            return .defaultPromptOptimizer
        }
        return HotkeyDefinition(
            keyCode: userDefaults.integer(forKey: UserDefaultsKeys.promptOptimizerHotkeyKeyCode),
            modifiers: HotkeyModifiers(
                rawValue: userDefaults.integer(forKey: UserDefaultsKeys.promptOptimizerHotkeyModifiers)
            )
        )
    }
}
