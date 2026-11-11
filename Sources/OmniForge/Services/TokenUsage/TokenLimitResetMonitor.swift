import Foundation

/// 限额重置监控 — 随限额刷新调用 `evaluate`，检测窗口 rollover 后按用户开关
/// 回调 `onCelebrate`（生产接全屏撒花 overlay；测试捕获调用）。
/// 仿 `TokenUsageAlertManager`：注入 configuration / strings 闭包，副作用可注入。
final class TokenLimitResetMonitor {
    private let detector = LimitResetDetector()
    private let configurationProvider: () -> TokenUsageConfiguration
    private let stringsProvider: () -> Strings
    private let defaults: UserDefaults
    private let now: () -> Date
    /// 庆祝副作用（showsToast / showsConfetti 已按配置解析；双关时不回调）。
    var onCelebrate: ((LimitResetEvent, _ showsToast: Bool, _ showsConfetti: Bool) -> Void)?
    /// 附加订阅者（宠物反应等）：与 `onCelebrate` 同时收到通知，互不影响。
    private var celebrateObservers: [(LimitResetEvent, _ showsToast: Bool, _ showsConfetti: Bool) -> Void] = []

    /// 追加订阅限额重置（多播；原 `onCelebrate` 单播保留兼容）。
    func addCelebrateObserver(
        _ observer: @escaping (LimitResetEvent, _ showsToast: Bool, _ showsConfetti: Bool) -> Void
    ) {
        celebrateObservers.append(observer)
    }

    init(
        configuration: @escaping () -> TokenUsageConfiguration,
        stringsProvider: @escaping () -> Strings = { L10n().s },
        userDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.configurationProvider = configuration
        self.stringsProvider = stringsProvider
        self.defaults = userDefaults
        self.now = now
    }

    /// 消费全量限额快照（随 TokenUsageManager 每次 apply 后调用）。
    func evaluate(limits: [TokenUsageProvider: ProviderUsageLimits]) {
        evaluate(limits: limits, at: now())
    }

    /// 显式时间判定（防抖 / rollover 边界测试可控）。
    func evaluate(limits: [TokenUsageProvider: ProviderUsageLimits], at now: Date) {
        let snapshot = LimitResetDetector.loadSnapshot(defaults)
        let (events, updated) = detector.evaluate(
            readings: limits.limitResetReadings(strings: stringsProvider()),
            snapshot: snapshot,
            now: now.timeIntervalSince1970
        )
        LimitResetDetector.saveSnapshot(updated, defaults)
        guard let first = events.first else { return }

        let configuration = configurationProvider()
        let showsToast = configuration.resetToastEnabled
        let showsConfetti = configuration.resetConfettiEnabled
        guard showsToast || showsConfetti else { return }
        onCelebrate?(first, showsToast, showsConfetti)
        for observer in celebrateObservers {
            observer(first, showsToast, showsConfetti)
        }
    }

    /// 静默闹钟路径入口（TokenResetAlarmScheduler 到点直调）：不依赖新拉取读数，
    /// 按已知窗口直接触发。与轮询路径共享 `lastEventAt` cooldown（1h）— 任一路径
    /// 先报即压制另一路径；上一窗口用量低于 `minDrop`（没怎么用）不报。
    /// 写入 lastEventAt 的时机与 evaluate 对齐（先记后按开关过滤）。
    func fireAlarm(
        provider: TokenUsageProvider,
        windowKey: String,
        windowLabel: String,
        previousPercent: Double
    ) {
        guard previousPercent >= detector.minDrop else { return }
        let timestamp = now().timeIntervalSince1970
        var snapshot = LimitResetDetector.loadSnapshot(defaults)
        if let last = snapshot.lastEventAt[windowKey], timestamp - last < detector.cooldown {
            return
        }
        snapshot.lastEventAt[windowKey] = timestamp
        LimitResetDetector.saveSnapshot(snapshot, defaults)

        let configuration = configurationProvider()
        let showsToast = configuration.resetToastEnabled
        let showsConfetti = configuration.resetConfettiEnabled
        guard showsToast || showsConfetti else { return }
        let event = LimitResetEvent(
            provider: provider,
            windowKey: windowKey,
            windowLabel: windowLabel,
            previousPercent: previousPercent
        )
        onCelebrate?(event, showsToast, showsConfetti)
        for observer in celebrateObservers {
            observer(event, showsToast, showsConfetti)
        }
    }
}
