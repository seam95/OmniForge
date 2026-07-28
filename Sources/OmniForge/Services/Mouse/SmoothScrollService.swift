import AppKit
import ApplicationServices
import Combine
import CoreGraphics

/// 把鼠标滚轮的离散跳跃转换为短滑行：一个 tap 吞掉每次滚轮刻度，
/// 把它的距离作为一串连续像素事件回放，像触摸设备那样缓出。
///
/// 只处理真实的滚轮刻度（isContinuous == 0）；触控板、Magic Mouse
/// 和惯性原样透传。tap 位于头部，使滚动反转器（尾部追加）仍能看到
/// 合成流并翻转它——两个特性可组合。特性关闭时 tap 和定时器都不
/// 存在。需要辅助功能权限。
final class SmoothScrollService: ObservableObject {
    static let shared = SmoothScrollService()

    /// 事件 tap 安装中为 true。
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    /// 标记合成事件，使 tap 永不重新处理自己的输出。
    private static let syntheticTag: Int64 = 0x564F5253  // "VORS"

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var frameTimer: Timer?
    /// 每轴的剩余滑行距离（像素）。仅在主线程触碰（tap 回调和定时器
    /// 都在主 run loop）。
    private var remainingVertical: Double = 0
    private var remainingHorizontal: Double = 0
    /// 启动或喂入滑行的滚轮事件的修饰符，在合成事件上回放，使 shift
    /// 或 option 滚动保持其含义。
    private var currentFlags: CGEventFlags = []
    /// 系统自然滚动方向的符号修正，在滑行开始时采样。
    private var postSign: Double = 1
    private let userDefaults: UserDefaults
    private let featureAvailable: () -> Bool
    private let permissionGranted: () -> Bool
    private let startOverride: (() throws -> Void)?
    private let stopOverride: (() -> Void)?

    init(
        userDefaults: UserDefaults = .standard,
        featureAvailable: @escaping () -> Bool = {
            MainActor.assumeIsolated { FeatureRuntime.shared.isAvailable(.smoothScroll) }
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
            featureEnabled: userDefaults.bool(forKey: UserDefaultsKeys.smoothScrollEnabled),
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
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<SmoothScrollService>.fromOpaque(userInfo).takeUnretainedValue()
                return service.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { throw MouseServiceError.eventTapCreationFailed(service: "SmoothScrollService") }

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
        stopGlide()
        stopOverride?()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS 会在 tap 卡顿或会话锁定时禁用它；重新武装。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        // 自己的滑行流再次经过 tap。
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticTag else {
            return Unmanaged.passUnretained(event)
        }
        // 触摸设备和连续滚轮本身已经平滑。
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
              event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0,
              event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0
        else { return Unmanaged.passUnretained(event) }
        // Control-滚动驱动屏幕缩放；保持其步进可预测。
        guard !event.flags.contains(.maskControl) else {
            return Unmanaged.passUnretained(event)
        }

        // 一个进程自己投递的事件会跳过它自身的 tap（已验证），因此
        // 滚动反转器永远看不到滑行流：当它开启时，滚轮的垂直翻转
        // 改在这里应用。
        let invert = ScrollInverter.shared.isRunning ? -1.0 : 1.0
        let vertical = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * invert
        let horizontal = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        guard vertical != 0 || horizontal != 0 else {
            return Unmanaged.passUnretained(event)
        }

        let step = Double(SmoothScrollSupport.sanitizedStep(
            UserDefaults.standard.integer(forKey: UserDefaultsKeys.smoothScrollStep)))
        remainingVertical = SmoothScrollSupport.remaining(afterTicks: vertical,
                                                          step: step,
                                                          current: remainingVertical)
        remainingHorizontal = SmoothScrollSupport.remaining(afterTicks: horizontal,
                                                            step: step,
                                                            current: remainingHorizontal)
        currentFlags = event.flags
        if frameTimer == nil {
            postSign = SmoothScrollSupport.postedDelta(1, naturalScrolling: Self.naturalScrollingOn())
        }
        startGlideIfNeeded()
        // 刻度本身被吞掉；滑行回放其距离。
        return nil
    }

    // MARK: - 滑行

    private func startGlideIfNeeded() {
        guard frameTimer == nil else { return }
        let timer = Timer(timeInterval: SmoothScrollSupport.frameInterval, repeats: true) { [weak self] _ in
            self?.emitFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
        emitFrame()
    }

    private func stopGlide() {
        frameTimer?.invalidate()
        frameTimer = nil
        remainingVertical = 0
        remainingHorizontal = 0
    }

    private func emitFrame() {
        let vertical = SmoothScrollSupport.frameDelta(remaining: remainingVertical)
        let horizontal = SmoothScrollSupport.frameDelta(remaining: remainingHorizontal)
        remainingVertical -= vertical
        remainingHorizontal -= horizontal

        if vertical != 0 || horizontal != 0 {
            post(vertical: vertical, horizontal: horizontal)
        }
        if remainingVertical == 0, remainingHorizontal == 0 {
            frameTimer?.invalidate()
            frameTimer = nil
        }
    }

    private func post(vertical: Double, horizontal: Double) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32((vertical * postSign).rounded()),
                                  wheel2: Int32((horizontal * postSign).rounded()),
                                  wheel3: 0) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
        event.flags = currentFlags
        event.post(tap: .cghidEventTap)
    }

    /// 用户的「自然滚动」系统偏好（macOS 默认：开启）。
    private static func naturalScrollingOn() -> Bool {
        (UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["com.apple.swipescrolldirection"] as? Bool) ?? true
    }
}
