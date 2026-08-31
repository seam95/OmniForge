import Carbon
import Cocoa
import CoreGraphics
import Foundation

/// 锁定内核的 CGEventTap 实现（SPEC D3/D4）：吞掉会话内全部 HID 事件
/// （内建 + 外接 + 蓝牙的键盘 / 触控板 / 鼠标），并以「长按任意鼠标/触控板按钮 3 秒」
/// 作为解锁手势。tap 挂主线程 runloop，回调与进度定时器均在主线程。
///
/// 安全边界：Touch ID 与电源键不经过会话 tap，无法拦截（SPEC 非目标）；
/// tap 随进程存活，应用崩溃 / 被杀时拦截自动失效（SPEC D11）。
final class CGCleaningInputInterceptor: CleaningInputIntercepting {
    var onHoldProgress: ((Double) -> Void)?
    var onHoldSatisfied: (() -> Void)?

    /// 解锁所需持续按压时长（秒）。
    private let holdDuration: TimeInterval
    private var holdEvaluator: HoldToUnlockEvaluator
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var progressTimer: DispatchSourceTimer?

    init(holdDuration: TimeInterval = 3) {
        self.holdDuration = holdDuration
        self.holdEvaluator = HoldToUnlockEvaluator(requiredDuration: holdDuration)
    }

    deinit {
        stop()
    }

    // MARK: - CleaningInputIntercepting

    /// 创建并启动会话事件 tap；返回 false 表示创建失败（通常是辅助功能权限缺失）。
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let eventMask = CGEventType.lockedEvents.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<CGCleaningInputInterceptor>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                return interceptor.handleEvent(type: type)
            },
            userInfo: userInfo
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        stopProgressTimer()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        holdEvaluator.pressEnded()
    }

    // MARK: - 事件处理（tap 回调，主线程）

    private func handleEvent(type: CGEventType) -> Unmanaged<CGEvent>? {
        // tap 被系统超时禁用时自动重启，避免拦截意外失效。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            holdEvaluator.pressBegan(at: Date())
            startProgressTimer()
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            holdEvaluator.pressEnded()
            stopProgressTimer()
            onHoldProgress?(0)
        default:
            break
        }

        // 清洁期间所有输入事件一律吞掉（SPEC D3）。
        return nil
    }

    // MARK: - 长按进度

    private func startProgressTimer() {
        stopProgressTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.06, repeating: 0.06)
        timer.setEventHandler { [weak self] in
            self?.tickHoldProgress()
        }
        timer.resume()
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.cancel()
        progressTimer = nil
    }

    private func tickHoldProgress() {
        guard holdEvaluator.isHolding else {
            stopProgressTimer()
            return
        }
        let now = Date()
        if holdEvaluator.isSatisfied(at: now) {
            holdEvaluator.pressEnded()
            stopProgressTimer()
            onHoldSatisfied?()
        } else {
            onHoldProgress?(holdEvaluator.progress(at: now))
        }
    }
}

private extension CGEventType {
    /// 清洁模式需要拦截的事件集合：键盘（含修饰键变化）、鼠标三类按键（含拖动）、
    /// 移动、滚轮与触笔。未列出的系统级事件（tapDisabled* 等）单独处理。
    static let lockedEvents: [CGEventType] = [
        .keyDown,
        .keyUp,
        .flagsChanged,
        .leftMouseDown,
        .leftMouseUp,
        .leftMouseDragged,
        .rightMouseDown,
        .rightMouseUp,
        .rightMouseDragged,
        .otherMouseDown,
        .otherMouseUp,
        .otherMouseDragged,
        .mouseMoved,
        .scrollWheel,
        .tabletPointer,
    ]
}
