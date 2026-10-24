import XCTest
@testable import OmniForge

/// 清洁模式状态机与超时兜底（SPEC §6）。
@MainActor
final class CleaningModeManagerTests: XCTestCase {
    private var interceptor: FakeCleaningInputInterceptor!
    private var overlay: FakeCleaningOverlayPresenter!
    private var scheduler: FakeCleaningTimeoutScheduler!
    private var systemEvents: FakeCleaningSystemEventObserver!
    private var userDefaults: UserDefaults!
    private var defaultsSuiteName = ""
    private var startedNotifications = 0

    override func setUp() {
        super.setUp()
        interceptor = FakeCleaningInputInterceptor()
        overlay = FakeCleaningOverlayPresenter()
        scheduler = FakeCleaningTimeoutScheduler()
        systemEvents = FakeCleaningSystemEventObserver()
        defaultsSuiteName = "CleaningModeManagerTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: defaultsSuiteName)
        startedNotifications = 0
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDidStart), name: CleaningModeManager.didStartNotification, object: nil
        )
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        userDefaults = nil
        NotificationCenter.default.removeObserver(self)
        super.tearDown()
    }

    @objc private func handleDidStart() { startedNotifications += 1 }

    private func makeManager() -> CleaningModeManager {
        CleaningModeManager(
            interceptor: interceptor,
            overlayPresenter: overlay,
            timeoutScheduler: scheduler,
            systemEventObserver: systemEvents,
            defaults: userDefaults
        )
    }

    // MARK: - 状态机

    func test_键盘清洁_锁输入且显示提示窗不建遮罩() {
        let manager = makeManager()
        XCTAssertTrue(manager.start(.keyboard))
        XCTAssertEqual(manager.state, .active(.keyboard))
        XCTAssertTrue(interceptor.isRunning)
        XCTAssertFalse(overlay.isPresented)
        XCTAssertTrue(overlay.isHintPresented)
        XCTAssertEqual(startedNotifications, 1)

        manager.stop()
        XCTAssertFalse(overlay.isHintPresented)
    }

    func test_屏幕清洁_锁输入且建遮罩() {
        let manager = makeManager()
        XCTAssertTrue(manager.start(.screen))
        XCTAssertEqual(manager.state, .active(.screen))
        XCTAssertTrue(interceptor.isRunning)
        XCTAssertTrue(overlay.isPresented)
        XCTAssertFalse(overlay.isHintPresented)
        XCTAssertEqual(overlay.presentedStyle, .black)
    }

    func test_运行中不允许再启动() {
        let manager = makeManager()
        XCTAssertTrue(manager.start(.keyboard))
        XCTAssertFalse(manager.start(.screen))
        XCTAssertEqual(manager.state, .active(.keyboard))
        XCTAssertEqual(startedNotifications, 1)
    }

    func test_权限缺失启动失败不改状态() {
        interceptor.startResult = false
        let manager = makeManager()
        XCTAssertFalse(manager.start(.keyboard))
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(overlay.isPresented)
        XCTAssertEqual(startedNotifications, 0)
    }

    func test_stop撤下全部资源且幂等() {
        let manager = makeManager()
        XCTAssertTrue(manager.start(.screen))
        manager.stop()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.activeSince)
        XCTAssertFalse(interceptor.isRunning)
        XCTAssertFalse(overlay.isPresented)
        XCTAssertTrue(scheduler.allCancelled)

        manager.stop()
        XCTAssertEqual(manager.state, .idle)
    }

    // MARK: - 长按解锁

    func test_长按满足回调触发停止() {
        let manager = makeManager()
        XCTAssertTrue(manager.start(.keyboard))
        interceptor.simulateHoldSatisfied()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(interceptor.isRunning)
    }

    func test_长按进度两种模式均透传() {
        let manager = makeManager()
        XCTAssertTrue(manager.start(.keyboard))
        interceptor.simulateHoldProgress(0.4)
        XCTAssertEqual(overlay.holdProgress ?? 0, 0.4, accuracy: 0.001)

        manager.stop()
        XCTAssertNil(overlay.holdProgress)

        XCTAssertTrue(manager.start(.screen))
        interceptor.simulateHoldProgress(0.7)
        XCTAssertEqual(overlay.holdProgress ?? 0, 0.7, accuracy: 0.001)

        manager.stop()
        XCTAssertNil(overlay.holdProgress)
    }

    // MARK: - 超时兜底

    func test_超时档位到期自动退出() {
        let manager = makeManager()
        manager.timeout = .minutes(5)
        XCTAssertTrue(manager.start(.keyboard))
        XCTAssertEqual(scheduler.scheduled.count, 1)
        XCTAssertEqual(scheduler.scheduled[0].seconds, 300, accuracy: 0.001)

        scheduler.scheduled[0].fire()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertTrue(scheduler.allCancelled)
    }

    func test_关闭超时不排程() {
        let manager = makeManager()
        manager.timeout = .off
        XCTAssertTrue(manager.start(.screen))
        XCTAssertTrue(scheduler.scheduled.isEmpty)
    }

    func test_运行中调整档位重排计时() {
        let manager = makeManager()
        manager.timeout = .minutes(10)
        XCTAssertTrue(manager.start(.keyboard))
        manager.timeout = .minutes(30)
        XCTAssertEqual(scheduler.scheduled.count, 2)
        XCTAssertEqual(scheduler.scheduled[1].seconds, 1800, accuracy: 0.001)
        XCTAssertTrue(scheduler.scheduled[0].cancelled)
    }

    // MARK: - 设置持久化

    func test_遮罩颜色与超时档位持久化往返() {
        let manager = makeManager()
        manager.overlayStyle = .white
        manager.timeout = .minutes(15)
        let reloaded = makeManager()
        XCTAssertEqual(reloaded.overlayStyle, .white)
        XCTAssertEqual(reloaded.timeout, .minutes(15))
    }

    func test_非法持久化值回落默认() {
        userDefaults.set("pink", forKey: UserDefaultsKeys.cleaningModeOverlayStyle)
        userDefaults.set(99, forKey: UserDefaultsKeys.cleaningModeTimeoutMinutes)
        let manager = makeManager()
        XCTAssertEqual(manager.overlayStyle, .black)
        XCTAssertEqual(manager.timeout, .minutes(10))
    }

    func test_屏幕清洁运行中切换颜色即时换肤() {
        let manager = makeManager()
        XCTAssertTrue(manager.start(.screen))
        manager.overlayStyle = .white
        XCTAssertEqual(overlay.presentedStyle, .white)
    }

    /// 设置项为 UserDefaults 背书的计算属性，setter 必须显式发刷新通知，
    /// 否则详情页选中态不重绘（真机回归：纯黑/纯白切换看似无反应）。
    func test_设置变更发出刷新通知() {
        let manager = makeManager()
        var emissions = 0
        let cancellable = manager.objectWillChange.sink { emissions += 1 }
        manager.overlayStyle = .white
        manager.timeout = .minutes(15)
        XCTAssertEqual(emissions, 2)
        withExtendedLifetime(cancellable) {}
    }

    // MARK: - 可用性联动

    func test_功能不可用强制退出() {
        let manager = makeManager()
        XCTAssertTrue(manager.start(.screen))
        manager.syncWithAvailability(isAvailable: false)
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(overlay.isPresented)
    }

    // MARK: - 系统中断（锁屏 / 睡眠 / 会话切换）

    func test_仅会话期间订阅系统事件() {
        let manager = makeManager()
        XCTAssertFalse(systemEvents.isObserving)

        XCTAssertTrue(manager.start(.keyboard))
        XCTAssertTrue(systemEvents.isObserving)

        manager.stop()
        XCTAssertFalse(systemEvents.isObserving)
    }

    func test_启动失败不订阅系统事件() {
        interceptor.startResult = false
        let manager = makeManager()
        XCTAssertFalse(manager.start(.screen))
        XCTAssertFalse(systemEvents.isObserving)
    }

    func test_锁屏等系统中断即退出清洁并撤下全部资源() {
        let manager = makeManager()
        XCTAssertTrue(manager.start(.screen))
        XCTAssertTrue(overlay.isPresented)

        systemEvents.simulateInterrupt()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.activeSince)
        XCTAssertFalse(interceptor.isRunning)
        XCTAssertFalse(overlay.isPresented)
        XCTAssertTrue(scheduler.allCancelled)
        XCTAssertFalse(systemEvents.isObserving)
    }

    func test_键盘清洁同样响应系统中断() {
        let manager = makeManager()
        XCTAssertTrue(manager.start(.keyboard))
        systemEvents.simulateInterrupt()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(overlay.isHintPresented)
        XCTAssertFalse(interceptor.isRunning)
    }

    func test_系统收回拦截事件即退出且不重装tap() {
        let manager = makeManager()
        XCTAssertTrue(manager.start(.keyboard))

        interceptor.simulateSystemReclaimed()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(interceptor.isRunning)
        XCTAssertFalse(overlay.isHintPresented)
        XCTAssertFalse(systemEvents.isObserving)
    }

    func test_系统中断后重置状态不残留() {
        let manager = makeManager()
        XCTAssertTrue(manager.start(.screen))
        systemEvents.simulateInterrupt()

        // 中断退出后可再次启动，且重新订阅监听。
        XCTAssertTrue(manager.start(.keyboard))
        XCTAssertTrue(systemEvents.isObserving)
        XCTAssertEqual(manager.state, .active(.keyboard))
    }
}

// MARK: - 假实现

private final class FakeCleaningInputInterceptor: CleaningInputIntercepting {
    var onHoldProgress: ((Double) -> Void)?
    var onHoldSatisfied: (() -> Void)?
    var onSystemReclaimed: (() -> Void)?
    var startResult = true
    private(set) var isRunning = false

    func start() -> Bool {
        isRunning = startResult
        return startResult
    }

    func stop() { isRunning = false }

    func simulateHoldProgress(_ progress: Double) { onHoldProgress?(progress) }
    func simulateHoldSatisfied() { onHoldSatisfied?() }
    func simulateSystemReclaimed() { onSystemReclaimed?() }
}

@MainActor
private final class FakeCleaningSystemEventObserver: CleaningSystemEventObserving {
    private(set) var isObserving = false
    private var onInterrupt: (@MainActor () -> Void)?

    func start(onInterrupt: @escaping @MainActor () -> Void) {
        isObserving = true
        self.onInterrupt = onInterrupt
    }

    func stop() {
        isObserving = false
        onInterrupt = nil
    }

    func simulateInterrupt() { onInterrupt?() }
}

private final class FakeCleaningOverlayPresenter: CleaningOverlayPresenting {
    private(set) var isPresented = false
    private(set) var isHintPresented = false
    private(set) var presentedStyle: CleaningOverlayStyle?
    private(set) var holdProgress: Double?

    func present(style: CleaningOverlayStyle) {
        isPresented = true
        presentedStyle = style
    }

    func presentHint() {
        isHintPresented = true
    }

    func dismiss() {
        isPresented = false
        isHintPresented = false
        presentedStyle = nil
    }

    func setHoldProgress(_ progress: Double?) { holdProgress = progress }
}

private final class FakeCleaningTimeoutEntry: CleaningTimeoutCancellable {
    let seconds: TimeInterval
    private let action: () -> Void
    private(set) var cancelled = false

    init(seconds: TimeInterval, action: @escaping () -> Void) {
        self.seconds = seconds
        self.action = action
    }

    func fire() { action() }
    func cancel() { cancelled = true }
}

private final class FakeCleaningTimeoutScheduler: CleaningTimeoutScheduling {
    private(set) var scheduled: [FakeCleaningTimeoutEntry] = []

    var allCancelled: Bool { scheduled.allSatisfy(\.cancelled) }

    func schedule(after seconds: TimeInterval, action: @escaping () -> Void) -> CleaningTimeoutCancellable {
        let entry = FakeCleaningTimeoutEntry(seconds: seconds, action: action)
        scheduled.append(entry)
        return entry
    }
}
