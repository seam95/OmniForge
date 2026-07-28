import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import CoreGraphics

/// 把标准的 Back/Forward 侧键转换为对应的应用命令。Finder 和浏览器
/// 将这些命令暴露为 Command-[ 和 Command-]；其他 App 在提供相同菜单
/// 命令时也能继续工作。该 opt-in 特性关闭时不安装任何东西。修改型
/// 事件 tap 和菜单动作均需要辅助功能权限。
final class MouseNavigationService: ObservableObject {
    static let shared = MouseNavigationService()

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let userDefaults: UserDefaults
    private let featureAvailable: () -> Bool
    private let permissionGranted: () -> Bool
    private let startOverride: (() throws -> Void)?
    private let stopOverride: (() -> Void)?

    init(
        userDefaults: UserDefaults = .standard,
        featureAvailable: @escaping () -> Bool = {
            MainActor.assumeIsolated { FeatureRuntime.shared.isAvailable(.mouseNavigation) }
        },
        permissionGranted: @escaping () -> Bool = { AXIsProcessTrusted() },
        startOverride: (() throws -> Void)? = nil,
        stopOverride: (() -> Void)? = nil
    ) {
        self.userDefaults = userDefaults
        self.featureAvailable = featureAvailable
        self.permissionGranted = permissionGranted
        self.startOverride = startOverride
        self.stopOverride = stopOverride
    }

    func syncWithPreferences() {
        synchronize(retry: false)
    }

    func retry() { synchronize(retry: true) }

    var runState: FeatureRunState {
        let input = gateInput
        return FeatureRunState.resolve(
            isEnabled: input.isAvailable && input.featureEnabled,
            isRunning: isRunning,
            hasPermission: input.hasPermission,
            lastError: lastError
        )
    }

    func suspend() {
        removeEventTap()
        isRunning = false
        lastError = nil
    }

    private var gateInput: MouseRunGate.Input {
        .init(
            isAvailable: featureAvailable(),
            featureEnabled: userDefaults.bool(forKey: UserDefaultsKeys.mouseNavigationEnabled),
            hasPermission: permissionGranted()
        )
    }

    private func synchronize(retry: Bool) {
        var running = isRunning
        var error = lastError
        MouseRunGate.synchronize(
            input: gateInput,
            retry: retry,
            isRunning: &running,
            lastError: &error,
            start: { [self] in try installEventTap() },
            stop: { [self] in removeEventTap() }
        )
        isRunning = running
        lastError = error
    }

    private func installEventTap() throws {
        if let startOverride {
            try startOverride()
            return
        }
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDragged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<MouseNavigationService>.fromOpaque(userInfo).takeUnretainedValue()
                return service.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { throw MouseServiceError.eventTapCreationFailed(service: "MouseNavigationService") }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEventTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        stopOverride?()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .otherMouseDown || type == .otherMouseUp || type == .otherMouseDragged,
              let direction = MouseNavigationSupport.direction(
                forButtonNumber: event.getIntegerValueField(.mouseEventButtonNumber)) else {
            return Unmanaged.passUnretained(event)
        }

        if type == .otherMouseDown {
            // 立即离开事件 tap 回调；AX 菜单遍历可能耗时数毫秒，绝不能
            // 让 tap 超时。
            DispatchQueue.main.async { [weak self] in
                self?.perform(direction)
            }
        }
        // 吞掉完整的侧键手势。替换 Down 后放行其 Up 或 Drag 会让应用
        // 收到一个不匹配的鼠标事件。
        return nil
    }

    private enum MenuPressOutcome {
        case pressed
        case pressFailed
        case noNavigationCommand
    }

    private func perform(_ direction: MouseNavigationDirection) {
        let character = MouseNavigationSupport.commandCharacter(for: direction)
        switch pressMenuItem(commandCharacter: character) {
        case .pressed:
            return
        case .pressFailed:
            postCommand(direction)
        case .noNavigationCommand:
            // 此 App 中没有已验证的 Back 或 Forward。盲目投递快捷键不是
            // 选项：更深层菜单中同样的按键是编辑命令（左移代码、重排图层），
            // 误触的侧键绝不能触碰文档。
            return
        }
    }

    /// 优先使用应用实际启用的菜单项。这保留了应用特有行为，且与键盘
    /// 布局无关。下面的合成快捷键仅作为找到的项拒绝 AXPress 时的回退。
    private func pressMenuItem(commandCharacter: String) -> MenuPressOutcome {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .noNavigationCommand }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        // 繁忙的目标绝不能因 AX 数秒默认超时而卡住主线程。子菜单元素在
        // 下方遍历时获得相同的时限。
        AXUIElementSetMessagingTimeout(application, 0.35)
        guard let menuBar: AXUIElement = attribute(kAXMenuBarAttribute, from: application) else {
            return .noNavigationCommand
        }
        var visited = 0
        guard let item = findMenuItem(in: menuBar,
                                      commandCharacter: commandCharacter,
                                      depth: 0,
                                      visited: &visited) else { return .noNavigationCommand }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
            ? .pressed : .pressFailed
    }

    private func findMenuItem(in element: AXUIElement,
                              commandCharacter: String,
                              depth: Int,
                              visited: inout Int) -> AXUIElement? {
        // 深度 3 是顶层菜单的直接项（菜单栏、栏项、菜单、项）。Back 和
        // Forward 总在那里（Go、History）；子菜单中同样的按键组合属于
        // 编辑命令，被刻意排除在外。这也让遍历保持简短。
        guard depth <= 3, visited < 600 else { return nil }
        visited += 1
        AXUIElementSetMessagingTimeout(element, 0.35)

        let command: String? = attribute(kAXMenuItemCmdCharAttribute, from: element)
        let modifiers: NSNumber? = attribute(kAXMenuItemCmdModifiersAttribute, from: element)
        let enabled: NSNumber? = attribute(kAXEnabledAttribute, from: element)
        // AX 修饰符值 0 表示 Command 且无其他修饰符。
        if command == commandCharacter,
           modifiers?.uint32Value == 0,
           enabled?.boolValue != false {
            return element
        }

        // 达到深度上限的项不可能在其下方有匹配；跳过子元素拷贝为每个
        // 菜单项节省一次 AX 往返。
        guard depth < 3 else { return nil }
        let children: [AXUIElement] = attribute(kAXChildrenAttribute, from: element) ?? []
        for child in children {
            if let match = findMenuItem(in: child,
                                        commandCharacter: commandCharacter,
                                        depth: depth + 1,
                                        visited: &visited) {
                return match
            }
        }
        return nil
    }

    private func attribute<T>(_ name: String, from element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    private func postCommand(_ direction: MouseNavigationDirection) {
        let keyCode = direction == .back ? kVK_ANSI_LeftBracket : kVK_ANSI_RightBracket
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: CGKeyCode(keyCode),
                                 keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(keyCode),
                               keyDown: false) else { return }
        // 不用 keyboardSetUnicodeString：在快捷键事件上强制设置字符
        // 字符串会破坏目标应用的菜单按键等价分发，命令到达后仍无效。
        // 虚拟键加 Command 标志就是快捷键所需的全部。
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
