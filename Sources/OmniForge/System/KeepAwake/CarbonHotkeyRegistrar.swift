import Carbon
import Foundation

// MARK: - Token / Protocol

/// 已注册全局热键的不透明令牌。
struct HotkeyRegistrationToken: Equatable, Hashable {
    let id: UInt32
    /// 不透明 Carbon hotkey ref；测试可比较同一 ref。
    let hotKey: EventHotKeyRef?

    init(id: UInt32, hotKey: EventHotKeyRef? = nil) {
        self.id = id
        self.hotKey = hotKey
    }

    static func == (lhs: HotkeyRegistrationToken, rhs: HotkeyRegistrationToken) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// 可注入的 Carbon 热键系统边界；生产与测试共用同一错误映射。
protocol CarbonHotkeyFunctionTable: AnyObject {
    func registerEventHotKey(
        keyCode: UInt32,
        modifiers: UInt32,
        hotKeyID: EventHotKeyID,
        eventTarget: EventTargetRef,
        options: OptionBits,
        outHotKey: UnsafeMutablePointer<EventHotKeyRef?>
    ) -> OSStatus

    func unregisterEventHotKey(_ hotKey: EventHotKeyRef) -> OSStatus
}

@MainActor
protocol CarbonHotkeyRegistering: AnyObject {
    func register(
        keyCode: UInt32,
        carbonModifiers: UInt32,
        handler: @escaping () -> Void
    ) throws -> HotkeyRegistrationToken

    func unregister(_ token: HotkeyRegistrationToken) throws
    func isActive(_ token: HotkeyRegistrationToken) -> Bool
    func teardown()
}

// MARK: - Production function table

/// 直接封装 Carbon API；返回真实 OSStatus。
final class LiveCarbonHotkeyFunctions: CarbonHotkeyFunctionTable {
    func registerEventHotKey(
        keyCode: UInt32,
        modifiers: UInt32,
        hotKeyID: EventHotKeyID,
        eventTarget: EventTargetRef,
        options: OptionBits,
        outHotKey: UnsafeMutablePointer<EventHotKeyRef?>
    ) -> OSStatus {
        return RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            eventTarget,
            options,
            outHotKey
        )
    }

    func unregisterEventHotKey(_ hotKey: EventHotKeyRef) -> OSStatus {
        UnregisterEventHotKey(hotKey)
    }
}

// MARK: - Registrar

/// Carbon 全局热键注册器。
/// - 注册/注销失败抛出真实 OSStatus（`KeepAwakeError.hotkey*Failed`）。
/// - 仅 key-up 触发 handler；key-down 忽略。
/// - 测试通过 `dispatchHotkeyEvent` 注入事件，无需真实系统热键。
@MainActor
final class CarbonHotkeyRegistrar: CarbonHotkeyRegistering {
    static let signature: OSType = 0x494C4B41 // 'ILKA'

    private let functions: CarbonHotkeyFunctionTable
    private var nextID: UInt32 = 1
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandlerInstalled = false
    private var eventHandlerRef: EventHandlerRef?

    init(functions: CarbonHotkeyFunctionTable = LiveCarbonHotkeyFunctions()) {
        self.functions = functions
    }

    deinit {
        // 非 MainActor 隔离的最后手段：尽力注销。
        for (_, ref) in refs {
            _ = functions.unregisterEventHotKey(ref)
        }
    }

    func register(
        keyCode: UInt32,
        carbonModifiers: UInt32,
        handler: @escaping () -> Void
    ) throws -> HotkeyRegistrationToken {
        try ensureEventHandlerInstalled()

        let id = nextID
        nextID &+= 1
        if nextID == 0 { nextID = 1 }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        // 测试注入函数表时 target 可为任意；生产使用应用事件目标。
        let target = GetApplicationEventTarget() ?? OpaquePointer(bitPattern: 1)!
        let status = functions.registerEventHotKey(
            keyCode: keyCode,
            modifiers: carbonModifiers,
            hotKeyID: hotKeyID,
            eventTarget: target,
            options: 0,
            outHotKey: &ref
        )
        guard status == noErr, let ref else {
            throw KeepAwakeError.hotkeyRegistrationFailed(status: status)
        }

        handlers[id] = handler
        refs[id] = ref
        return HotkeyRegistrationToken(id: id, hotKey: ref)
    }

    func unregister(_ token: HotkeyRegistrationToken) throws {
        guard let ref = refs[token.id] else {
            handlers.removeValue(forKey: token.id)
            return
        }
        let status = functions.unregisterEventHotKey(ref)
        handlers.removeValue(forKey: token.id)
        refs.removeValue(forKey: token.id)
        guard status == noErr else {
            throw KeepAwakeError.hotkeyUnregistrationFailed(status: status)
        }
    }

    func isActive(_ token: HotkeyRegistrationToken) -> Bool {
        refs[token.id] != nil
    }

    /// 测试 / 事件桥：仅 isKeyUp 时触发 handler。
    func dispatchHotkeyEvent(id: UInt32, isKeyUp: Bool) {
        guard isKeyUp else { return }
        handlers[id]?()
    }

    func teardown() {
        let ids = Array(refs.keys)
        for id in ids {
            if let ref = refs[id] {
                _ = functions.unregisterEventHotKey(ref)
            }
            refs.removeValue(forKey: id)
            handlers.removeValue(forKey: id)
        }
    }

    // MARK: - Event handler install（生产路径）

    private func ensureEventHandlerInstalled() throws {
        guard !eventHandlerInstalled else { return }
        // 测试用 Fake 不依赖真实 InstallEventHandler；生产安装 keyboard hotkey 事件。
        // 通过 Unmanaged 桥接 self 会引入复杂生命周期；生产 handler 使用静态表。
        // 此处仅标记已安装；真实 Carbon 回调通过 SharedBridge 分发。
        CarbonHotkeyRegistrarBridge.shared.attach(self)
        eventHandlerInstalled = true
    }
}

// MARK: - 生产事件桥（弱引用 registrar）

/// 避免在 C 回调中强持有 registrar。
@MainActor
final class CarbonHotkeyRegistrarBridge {
    static let shared = CarbonHotkeyRegistrarBridge()
    weak var registrar: CarbonHotkeyRegistrar?

    func attach(_ registrar: CarbonHotkeyRegistrar) {
        self.registrar = registrar
        installIfNeeded()
    }

    private var installed = false

    private func installIfNeeded() {
        guard !installed else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            guard let event else { return noErr }
            var hk = EventHotKeyID()
            let err = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hk
            )
            guard err == noErr else { return err }
            let kind = GetEventKind(event)
            let isKeyUp = kind == UInt32(kEventHotKeyReleased)
            // 主线程派发
            DispatchQueue.main.async {
                Task { @MainActor in
                    CarbonHotkeyRegistrarBridge.shared.registrar?
                        .dispatchHotkeyEvent(id: hk.id, isKeyUp: isKeyUp)
                }
            }
            return noErr
        }
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            2,
            &eventTypes,
            nil,
            &handlerRef
        )
        if status == noErr {
            installed = true
        }
    }
}
