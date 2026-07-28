import Carbon
import ApplicationServices
import Cocoa
import CoreGraphics
import Foundation

/// 使用 CGEventTap 拦截输入法切换
/// 支持拦截 fn/Globe 键和系统配置的快捷键
final class KeyboardEventTapManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?

    /// 锁定状态回调
    var isLockedProvider: (() -> Bool)?

    /// 系统配置的输入法切换快捷键
    private var systemHotkeys: [SystemHotkeyReader.Hotkey] = []

    /// fn 键的上一个状态
    private var lastFnKeyState: Bool = false
    /// 是否正在阻止 fn 键的按下/释放序列
    private var isBlockingFnKeySequence: Bool = false

    deinit {
        stop()
    }

    func start() {
        guard eventTap == nil else { return }

        // 读取系统配置的快捷键
        reloadHotkeys()

        // 创建事件拦截器
        // 监听按键事件和修饰键变化（用于检测 fn 键）
        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue) |
                        (1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let manager = Unmanaged<KeyboardEventTapManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            print("[KeyboardEventTapManager] 无法创建事件拦截器，请检查辅助功能权限")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        runLoop = CFRunLoopGetCurrent()
        if let source = runLoopSource, let runLoop {
            CFRunLoopAddSource(runLoop, source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)

        var descriptions = systemHotkeys.map { describeHotkey($0) }
        descriptions.append("fn/🌐")
        print("[KeyboardEventTapManager] 事件拦截器已启动，拦截: \(descriptions.joined(separator: ", "))")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = runLoopSource, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }

        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }

        eventTap = nil
        runLoopSource = nil
        runLoop = nil
        print("[KeyboardEventTapManager] 事件拦截器已停止")
    }

    /// 重新加载快捷键配置
    func reloadHotkeys() {
        systemHotkeys = SystemHotkeyReader.readInputSourceHotkeys()
    }

    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // 如果事件拦截器被禁用，重新启用
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // 检查是否锁定
        guard isLockedProvider?() == true else {
            return Unmanaged.passUnretained(event)
        }

        // 处理修饰键变化（fn 键）
        if type == .flagsChanged {
            if shouldBlockFnKey(event: event) {
                print("[KeyboardEventTapManager] 拦截 fn/Globe 键")
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // 处理按键事件
        if type == .keyDown || type == .keyUp {
            if isInputSourceSwitchShortcut(event: event) {
                print("[KeyboardEventTapManager] 拦截输入法切换快捷键")
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    /// 检查是否应该阻止 fn 键
    private func shouldBlockFnKey(event: CGEvent) -> Bool {
        let flags = event.flags

        // 检查 fn 键状态
        // fn 键的标志位是 0x800000 (1 << 23)，对应 .maskSecondaryFn
        let fnPressed = flags.contains(.maskSecondaryFn)

        // 只有当 fn 键是单独按下时才阻止（用于切换输入法）
        // 如果同时按了其他修饰键，可能是其他功能
        let otherModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        let hasOtherModifiers = !flags.intersection(otherModifiers).isEmpty

        // 检测 fn 键按下（从未按下到按下的变化）
        if fnPressed && !lastFnKeyState && !hasOtherModifiers {
            lastFnKeyState = fnPressed
            isBlockingFnKeySequence = true
            return true
        }

        // 如果之前拦截了 fn 按下，也拦截释放，避免系统在释放时触发切换
        if !fnPressed && lastFnKeyState && isBlockingFnKeySequence {
            lastFnKeyState = fnPressed
            isBlockingFnKeySequence = false
            return true
        }

        lastFnKeyState = fnPressed
        if !fnPressed {
            isBlockingFnKeySequence = false
        }
        return false
    }

    /// 检查是否是输入法切换快捷键
    private func isInputSourceSwitchShortcut(event: CGEvent) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // 检查是否匹配任何配置的快捷键
        for hotkey in systemHotkeys {
            if keyCode == hotkey.keyCode && matchesModifiers(flags, hotkey.cgEventFlags) {
                return true
            }
        }

        return false
    }

    /// 检查修饰键是否匹配
    private func matchesModifiers(_ eventFlags: CGEventFlags, _ hotkeyFlags: CGEventFlags) -> Bool {
        let modifiersToCheck: [CGEventFlags] = [
            .maskShift,
            .maskControl,
            .maskAlternate,
            .maskCommand
        ]

        for modifier in modifiersToCheck {
            let eventHas = eventFlags.contains(modifier)
            let hotkeyHas = hotkeyFlags.contains(modifier)
            if eventHas != hotkeyHas {
                return false
            }
        }

        return true
    }

    /// 生成快捷键的可读描述
    private func describeHotkey(_ hotkey: SystemHotkeyReader.Hotkey) -> String {
        var parts: [String] = []

        if hotkey.modifiers & (1 << 18) != 0 { parts.append("⌃") }
        if hotkey.modifiers & (1 << 19) != 0 { parts.append("⌥") }
        if hotkey.modifiers & (1 << 17) != 0 { parts.append("⇧") }
        if hotkey.modifiers & (1 << 20) != 0 { parts.append("⌘") }
        if hotkey.modifiers & (1 << 23) != 0 { parts.append("fn") }

        let keyName: String
        switch hotkey.keyCode {
        case 49: keyName = "Space"
        case 57: keyName = "CapsLock"
        case 36: keyName = "Return"
        case 48: keyName = "Tab"
        default: keyName = "Key(\(hotkey.keyCode))"
        }
        parts.append(keyName)

        return parts.joined()
    }

    /// 请求辅助功能权限
    @available(*, deprecated, message: "请直接使用 AXIsProcessTrustedWithOptions")
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 检查是否有辅助功能权限
    @available(*, deprecated, message: "请直接使用 AXIsProcessTrusted")
    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// 获取当前系统配置的快捷键描述
    func getSystemHotkeyDescriptions() -> [String] {
        var descriptions = systemHotkeys.map { describeHotkey($0) }
        descriptions.append("fn/🌐")
        return descriptions
    }
}
