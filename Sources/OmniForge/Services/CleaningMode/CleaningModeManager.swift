import Foundation
import Combine

/// 清洁会话状态：`idle` 或正在进行的某种清洁动作。
enum CleaningSessionState: Equatable {
    case idle
    case active(CleaningMode)
}

/// 输入拦截层（锁定内核）抽象：吞掉全部 HID 事件并判定长按解锁。
/// 真实现为 CGEventTap；测试用假实现驱动回调。
protocol CleaningInputIntercepting: AnyObject {
    /// 长按进度变化（0...1），主线程回调；驱动屏幕清洁遮罩进度环。
    var onHoldProgress: ((Double) -> Void)? { get set }
    /// 长按满足解锁时长（主线程回调），应退出清洁状态。
    var onHoldSatisfied: (() -> Void)? { get set }
    /// 启动拦截；返回 false 表示事件 tap 创建失败（通常是辅助功能权限缺失）。
    func start() -> Bool
    /// 停止拦截并恢复输入。
    func stop()
}

/// 屏幕清洁遮罩与键盘清洁提示的呈现抽象；测试用假实现断言调用时序。
protocol CleaningOverlayPresenting: AnyObject {
    /// 屏幕清洁：在所有屏幕显示纯色遮罩（含中央提示）。
    func present(style: CleaningOverlayStyle)
    /// 键盘清洁：仅显示中央提示窗（无遮罩，5 秒淡出，SPEC D8）。
    func presentHint()
    /// 撤下全部遮罩与提示窗并恢复光标。
    func dismiss()
    /// 更新长按进度环；nil 表示隐藏。
    func setHoldProgress(_ progress: Double?)
}

/// 超时兜底调度的最小抽象；测试手动触发以推进时间。
protocol CleaningTimeoutCancellable: AnyObject {
    func cancel()
}

protocol CleaningTimeoutScheduling: AnyObject {
    @discardableResult
    func schedule(after seconds: TimeInterval, action: @escaping () -> Void) -> CleaningTimeoutCancellable
}

/// 清洁模式管理器：两种动作共享的状态机（SPEC D1）。
/// 启动顺序：拦截 → 遮罩（仅屏幕清洁）→ 超时兜底 → 广播启动通知（控制中心面板收起）。
/// 停止顺序：先撤遮罩（拦截仍有效，避免撤罩过程误触），再停拦截与计时。
@MainActor
final class CleaningModeManager: ObservableObject {
    /// 会话状态；`activeSince` 供详情页展示已持续时长。
    @Published private(set) var state: CleaningSessionState = .idle
    @Published private(set) var activeSince: Date?

    /// 启动成功广播（D14：控制中心面板收起）。
    static let didStartNotification = Notification.Name("cleaningModeDidStart")

    private let interceptor: CleaningInputIntercepting
    private let overlayPresenter: CleaningOverlayPresenting?
    private let timeoutScheduler: CleaningTimeoutScheduling
    private let defaults: UserDefaults
    private var timeoutCancellable: CleaningTimeoutCancellable?

    init(
        interceptor: CleaningInputIntercepting,
        overlayPresenter: CleaningOverlayPresenting?,
        timeoutScheduler: CleaningTimeoutScheduling,
        defaults: UserDefaults
    ) {
        self.interceptor = interceptor
        self.overlayPresenter = overlayPresenter
        self.timeoutScheduler = timeoutScheduler
        self.defaults = defaults
        bindInterceptor()
    }

    // MARK: - 设置（持久化）

    var overlayStyle: CleaningOverlayStyle {
        get { .fromPersistedValue(defaults.string(forKey: UserDefaultsKeys.cleaningModeOverlayStyle)) }
        set {
            defaults.set(newValue.rawValue, forKey: UserDefaultsKeys.cleaningModeOverlayStyle)
            // 屏幕清洁运行中即时换肤。
            if case .active(.screen) = state {
                overlayPresenter?.present(style: newValue)
            }
        }
    }

    var timeout: CleaningTimeout {
        get {
            .fromPersistedMinutes(
                defaults.object(forKey: UserDefaultsKeys.cleaningModeTimeoutMinutes) as? Int
                    ?? CleaningTimeout.standard.persistedMinutes
            )
        }
        set {
            defaults.set(newValue.persistedMinutes, forKey: UserDefaultsKeys.cleaningModeTimeoutMinutes)
            rescheduleTimeoutIfNeeded()
        }
    }

    // MARK: - 会话控制

    /// 启动清洁；拦截层创建失败（权限缺失）时不改变状态，返回 false。
    @discardableResult
    func start(_ mode: CleaningMode) -> Bool {
        guard state == .idle else { return false }
        guard interceptor.start() else { return false }

        state = .active(mode)
        activeSince = Date()

        switch mode {
        case .keyboard:
            overlayPresenter?.presentHint()
        case .screen:
            overlayPresenter?.present(style: overlayStyle)
        }

        scheduleTimeout()

        NotificationCenter.default.post(name: Self.didStartNotification, object: nil)
        return true
    }

    /// 退出清洁：撤遮罩 → 停拦截 → 清计时。幂等。
    func stop() {
        overlayPresenter?.setHoldProgress(nil)
        overlayPresenter?.dismiss()
        timeoutCancellable?.cancel()
        timeoutCancellable = nil
        interceptor.stop()
        state = .idle
        activeSince = nil
    }

    /// 功能可用性联动（FeatureRuntime adapter / teardown）：不可用即强制退出。
    func syncWithAvailability(isAvailable: Bool) {
        if !isAvailable {
            stop()
        }
    }

    // MARK: - 私有

    private func bindInterceptor() {
        interceptor.onHoldProgress = { [weak self] progress in
            guard let self, self.state != .idle else { return }
            self.overlayPresenter?.setHoldProgress(progress)
        }
        interceptor.onHoldSatisfied = { [weak self] in
            self?.stop()
        }
    }

    /// 排程（或重排）超时兜底计时；`.off` 不排程。
    private func scheduleTimeout() {
        timeoutCancellable?.cancel()
        timeoutCancellable = nil
        guard let seconds = timeout.seconds else { return }
        timeoutCancellable = timeoutScheduler.schedule(after: seconds) { [weak self] in
            self?.stop()
        }
    }

    /// 运行中调整超时档位：重排兜底计时。
    private func rescheduleTimeoutIfNeeded() {
        guard state != .idle else { return }
        scheduleTimeout()
    }
}

/// 生产超时调度：主队列一次性 DispatchSourceTimer。
final class DispatchCleaningTimeoutScheduler: CleaningTimeoutScheduling {
    func schedule(after seconds: TimeInterval, action: @escaping () -> Void) -> CleaningTimeoutCancellable {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + seconds, repeating: .never)
        timer.setEventHandler(handler: action)
        timer.resume()
        return DispatchCleaningTimeoutCancellable(timer: timer)
    }
}

private final class DispatchCleaningTimeoutCancellable: CleaningTimeoutCancellable {
    private let timer: DispatchSourceTimer

    init(timer: DispatchSourceTimer) {
        self.timer = timer
    }

    func cancel() {
        timer.cancel()
    }
}
