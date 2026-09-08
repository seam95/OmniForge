import AppKit
import ApplicationServices
import Combine
import CoreGraphics

/// 仅反转鼠标滚轮的滚动方向，让触控板保持 macOS 的自然滚动：一个
/// 在 HID 层（窗口服务器从滚轮刻度推导出像素 delta 之前）追加的
/// 修改型 tap，位于尾部，只翻转 line delta。
///
/// 滚轮检测：离散事件（isContinuous == 0）是滚轮；标记为连续的事件
/// 仅在不携带任何手势相位时才算滚轮。切换即时生效。需要辅助功能权限。
final class ScrollInverter: ObservableObject {
    static let shared = ScrollInverter()

    /// 事件 tap 已安装并在反转时为 true。
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// 最后一个携带手势相位的事件的时间戳（纳秒，事件时钟）——只有
    /// 触摸设备会发出这些。仅在 tap 回调中读写。
    private var lastGesturePhaseTimestamp: UInt64?
    private let userDefaults: UserDefaults
    private let featureAvailable: () -> Bool
    private let permissionGranted: () -> Bool
    private let startOverride: (() throws -> Void)?
    private let stopOverride: (() -> Void)?

    init(
        userDefaults: UserDefaults = .standard,
        featureAvailable: @escaping () -> Bool = {
            MainActor.assumeIsolated { FeatureRuntime.shared.isAvailable(.scrollInverter) }
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

    /// 应用持久化偏好；可重复安全调用。
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

    /// 无论偏好如何都强制停止 tap。用于 App 重置自身权限之前，使一个
    /// 被撤销的辅助功能授权永远不会留下一个活跃的 tap。
    func suspend() {
        removeEventTap()
        isRunning = false
        lastError = nil
    }

    private var gateInput: MouseRunGate.Input {
        .init(
            isAvailable: featureAvailable(),
            featureEnabled: userDefaults.bool(forKey: UserDefaultsKeys.scrollInverterEnabled),
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
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let inverter = Unmanaged<ScrollInverter>.fromOpaque(userInfo).takeUnretainedValue()
                return inverter.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { throw MouseServiceError.eventTapCreationFailed(service: "ScrollInverter") }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEventTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        stopOverride?()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS 会在 tap 卡顿或会话锁定时禁用它；重新武装。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

        // 本进程合成的滚轮（长截图自动滚动、平滑滚动滑行流）保持原方向：
        // 自动滚动的方向由长截图引擎自己决定，不能被滚轮方向偏好翻转。
        guard !SyntheticEventTag.isOurs(event) else { return Unmanaged.passUnretained(event) }

        let traits = ScrollWheelEventTraits(
            isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            scrollCount: event.getIntegerValueField(.scrollWheelEventScrollCount)
        )
        let timestamp = UInt64(event.timestamp)
        let secondsSinceGesturePhase = lastGesturePhaseTimestamp.map {
            Double(timestamp &- $0) / 1_000_000_000.0
        }
        if traits.momentumPhase != 0 || traits.scrollPhase != 0 {
            lastGesturePhaseTimestamp = timestamp
        }

        if ScrollInverterSupport.shouldInvertMouseWheel(traits,
                                                        secondsSinceLastGesturePhase: secondsSinceGesturePhase) {
            // 三个 delta 必须在任何 set 之前捕获：写入 line delta 会让系统
            // 据此重新推导 point 和 fixed-point 字段，因此取反一个重读值
            // 会把它翻回正值，反转在应用实际使用的连续事件字段上会静默
            // 自我抵消。仅垂直方向。
            let line = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let point = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            let fixedPoint = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -line)
            if traits.isContinuous {
                event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -point)
                event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixedPoint)
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
