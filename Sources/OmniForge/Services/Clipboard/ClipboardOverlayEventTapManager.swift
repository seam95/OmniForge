import AppKit
import CoreGraphics
import Foundation

struct ClipboardOverlayKeyDownEvent {
    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags
    let charactersIgnoringModifiers: String?
}

/// 剪切板窗口专用的事件拦截器：
/// - 在窗口以 non-activating 方式展示时，拦截 Enter/Esc/方向键等按键，避免影响原应用输入光标
/// - 监听鼠标点击：点击窗口外则关闭窗口（但不吞掉点击）
final class ClipboardOverlayEventTapManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?

    var isEnabledProvider: (() -> Bool)?
    var onKeyDown: ((ClipboardOverlayKeyDownEvent) -> Bool)?
    var onMouseDown: ((CGPoint) -> Void)?

    var isRunning: Bool {
        eventTap != nil
    }

    deinit {
        stop()
    }

    func start() {
        guard eventTap == nil else { return }

        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.leftMouseDown.rawValue) |
                        (1 << CGEventType.rightMouseDown.rawValue) |
                        (1 << CGEventType.otherMouseDown.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<ClipboardOverlayEventTapManager>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            print("[ClipboardOverlayEventTapManager] 无法创建事件拦截器，请检查“辅助功能/输入监控”权限")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        runLoop = CFRunLoopGetCurrent()
        if let source = runLoopSource, let runLoop {
            CFRunLoopAddSource(runLoop, source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
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
    }

    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard isEnabledProvider?() == true else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let nsEvent = NSEvent(cgEvent: event)
            let payload = ClipboardOverlayKeyDownEvent(
                keyCode: keyCode,
                modifierFlags: nsEvent?.modifierFlags ?? [],
                charactersIgnoringModifiers: nsEvent?.charactersIgnoringModifiers
            )
            if onKeyDown?(payload) == true {
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            onMouseDown?(event.location)
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

